# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository

Single-file bash project: `k8s-net-test.sh` is a self-contained Kubernetes multi-CNI network connectivity test suite. No build system, no dependencies beyond `kubectl` + `python3` (used only to parse Multus `network-status` annotation JSON). README.md is a short usage cheatsheet in Chinese.

## Running

```bash
./k8s-net-test.sh                                       # auto-detect env, auto-cleanup on exit
./k8s-net-test.sh --spiderpool-multus "spiderpool/l2-ens12"
./k8s-net-test.sh --skip-cleanup                        # keep namespace for debugging
./k8s-net-test.sh --kubeconfig ~/.kube/my-cluster
./k8s-net-test.sh --namespace <ns> --timeout 120        # override defaults
```

The script creates an ephemeral namespace `net-test-<epoch>`, applies test workloads, runs all phases, and deletes the namespace via `trap cleanup EXIT`. Exit code is non-zero iff any test failed. There are no unit tests — validation is running the script against a real cluster.

## Architecture

The script is structured as a linear pipeline driven by `main()` at the bottom of the file. Understanding these cross-cutting concerns is key to editing it safely:

**Adaptive detection (`preflight_check`).** Sets three globals — `MULTUS_INSTALLED`, `SPIDERPOOL_INSTALLED`, `LB_SUPPORTED` — by probing for specific CRDs (`network-attachment-definitions.k8s.cni.cncf.io`, `spidersubnets`/`spiderippools.spiderpool.spidernet.io`, `ipaddresspools.metallb.io`). Every subsequent phase gates Spiderpool-dependent logic on these flags and records `skip` instead of `fail` when the feature is absent. Node count <2 similarly downgrades cross-node tests to skip. **When adding a test that depends on an optional component, follow this pattern — do not hard-fail.**

**Three Pod "types" under test**, each with two replicas pinned to different nodes when possible:
- **Type A** (`pod-default-{1,2}`) — default CNI only.
- **Type B** (`pod-spider-{1,2}`) — Spiderpool via `v1.multus-cni.io/default-network` annotation, replacing the default network.
- **Type C** (`pod-dual-{1,2}`) — default CNI plus a Multus additional network via `k8s.v1.cni.cncf.io/networks`.

`create_resources` generates all three via heredoc'd YAML with `kc apply -f -`. A `http-server` pod (nc-based pseudo-HTTP on :8080) plus ClusterIP/NodePort/LoadBalancer Services back the Service tests, with a parallel `http-server-spider` + `svc-clusterip-spider` set when Spiderpool is present.

**Result accounting.** `record_result {pass|fail|skip} <desc>` is the single choke point; every test function must call it exactly once per assertion. The four counters (`PASS_COUNT`/`FAIL_COUNT`/`SKIP_COUNT`/`TOTAL_COUNT`) drive `print_report` and the exit code.

**`kc()` wrapper.** All kubectl invocations go through `kc` so `--kubeconfig` flag-splitting works uniformly. Do not call `kubectl` directly — use `kc`.

**Pod-exec helpers.** `exec_in_pod` wraps `kubectl exec` with a 10s in-pod `timeout`. `get_pod_ip` returns the default-network IP; `get_pod_multus_ip` parses the `k8s.v1.cni.cncf.io/network-status` annotation via inline python3 to pull the first non-`eth0` interface IP — this is the only way to reach a Type C pod's additional network.

**Node→Pod test fallback chain** (`test_node_to_pod`). First tries `kubectl debug node/...`; on failure, falls back to creating a `hostNetwork: true` one-shot pod pinned via `nodeName` and polling until `Succeeded`/`Failed`. Keep both paths when modifying — some clusters disable one or the other.

**Test phases** (run sequentially by `main`): pod↔pod (intra-type, cross-type matrix A↔B↔C), pod→Service (ClusterIP by IP + DNS, NodePort via backend node *and* backend-less node, LoadBalancer), multi-backend blackhole detection (`svc-clusterip-multi` with `http-server` + `http-server-2` across nodes; 10 in-pod curls, responses parsed for distinct backend hostnames to catch intermittent one-sided timeouts), node→pod, pod→external (`223.5.5.5` + `www.baidu.com`), DNS (`kubernetes.default.svc`, short-name, external), pod→APIServer (treats 401/403 as network-reachable pass), same-node vs cross-node TCP, MTU probe (DF ping sized to the source pod's egress-interface MTU — resolved via `ip route get` so Type C picks net1 for spider targets — falling back to 1400, plus a descending probe with `ping -M do`), hairpin, and NetworkPolicy deny-all round-trips (Ingress on the server, Egress on a client; both assert enforcement *and* recovery after deletion, with 20s polling that requires 2 consecutive failures before declaring enforcement).

## Editing notes

- `set -Eeuo pipefail` is active — unset vars fail the script. Default new globals or guard with `${VAR:-}`. `-E` keeps the ERR trap (`on_unexpected_error`) alive inside functions — don't drop it.
- Requires bash >= 4.4 (checked at startup): `declare -A` and empty-array expansion under `set -u`. macOS system bash 3.2 gets a clear error instead of a cryptic one.
- Service DNS names use the `.svc` short suffix (e.g. `svc-clusterip.<ns>.svc`), not `.svc.cluster.local` — resolves via the third resolv.conf search entry on any cluster domain. Don't "complete" them to FQDNs.
- Image defaults to `m.daocloud.io/docker.io/nicolaka/netshoot:v0.16` (DaoCloud mirror, pinned for reproducibility; `--image` overrides). If changing, verify `ping`, `curl`, `nslookup`, `nc -l -p <port> -w 1` are all available — the pseudo-HTTP server relies on busybox-style `nc`.
- `TEST_EXTERNAL_HOST="www.baidu.com"` / `TEST_EXTERNAL_IP="223.5.5.5"` target China-reachable endpoints by design; don't "fix" to google.com without thinking about where this runs.
- Annotations in heredocs use literal indented newlines when `SPIDERPOOL_SUBNET` is set (see `spider_annotations` in `create_resources`) — preserve that exact formatting or YAML parsing breaks.
- `--spiderpool-multus` sets both `SPIDERPOOL_DEFAULT_MULTUS` and `SPIDERPOOL_ADDITIONAL_MULTUS` to the same value; split them only if a test genuinely needs distinct NADs.
