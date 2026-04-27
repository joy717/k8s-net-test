#!/usr/bin/env bash
#
# k8s-net-test.sh — Kubernetes 多 CNI 网络连通性全面验证脚本
#
# 支持的 Pod 网络类型:
#   A) 默认 CNI
#   B) Spiderpool 作为默认网络 (multus default-network)
#   C) 默认 CNI + Spiderpool 附加网络 (multus additional network)
#
# 验证场景:
#   1. Pod → Pod (同节点 / 跨节点, 各 CNI 类型互通)
#   2. Pod → Service (ClusterIP / NodePort / LoadBalancer)
#   3. Node → Pod
#   4. Pod → 外部网络 (互联网)
#   5. Pod → Kubernetes API Server
#   6. Pod → CoreDNS 解析
#   7. NetworkPolicy 连通性 (如启用)
#
# 使用方式:
#   chmod +x k8s-net-test.sh
#   ./k8s-net-test.sh [--namespace <ns>] [--skip-cleanup] [--timeout <seconds>]
#                     [--spiderpool-subnet <name>] [--spiderpool-multus <name>]
#                     [--kubeconfig <path>]

set -euo pipefail

# ============================================================================
# 配置
# ============================================================================
NAMESPACE="net-test-$(date +%s)"
IMAGE="m.daocloud.io/docker.io/nicolaka/netshoot"
TIMEOUT=120          # 等待 Pod Ready 的超时时间 (秒)
SKIP_CLEANUP=false
TEST_EXTERNAL_HOST="www.baidu.com"
TEST_EXTERNAL_IP="223.5.5.5"  # 阿里 DNS, 用于测试外部连通性

# Spiderpool / Multus 相关配置
SPIDERPOOL_DEFAULT_MULTUS="spiderpool/l2-ens12"    # Type B: spiderpool 作为默认网络
SPIDERPOOL_ADDITIONAL_MULTUS="spiderpool/l2-ens12"  # Type C: spiderpool 作为附加网络
SPIDERPOOL_SUBNET=""  # 可选: 指定 spiderpool subnet 名称

KUBECONFIG_FLAG=""

# ============================================================================
# 颜色输出
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ============================================================================
# 计数器
# ============================================================================
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

# ============================================================================
# 参数解析
# ============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)       NAMESPACE="$2"; shift 2 ;;
        --skip-cleanup)    SKIP_CLEANUP=true; shift ;;
        --timeout)         TIMEOUT="$2"; shift 2 ;;
        --spiderpool-subnet)      SPIDERPOOL_SUBNET="$2"; shift 2 ;;
        --spiderpool-multus)      SPIDERPOOL_DEFAULT_MULTUS="$2"; SPIDERPOOL_ADDITIONAL_MULTUS="$2"; shift 2 ;;
        --kubeconfig)      KUBECONFIG_FLAG="--kubeconfig $2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^#//;s/^ //'
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ============================================================================
# 工具函数
# ============================================================================
kc() {
    # shellcheck disable=SC2086
    kubectl $KUBECONFIG_FLAG "$@"
}

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_skip()  { echo -e "${CYAN}[SKIP]${NC}  $*"; }
log_section() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

record_result() {
    local status="$1"
    local desc="$2"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    case "$status" in
        pass) PASS_COUNT=$((PASS_COUNT + 1)); log_ok "$desc" ;;
        fail) FAIL_COUNT=$((FAIL_COUNT + 1)); log_fail "$desc" ;;
        skip) SKIP_COUNT=$((SKIP_COUNT + 1)); log_skip "$desc" ;;
    esac
}

# 在 Pod 内执行命令, 带超时
exec_in_pod() {
    local pod="$1"; shift
    kc exec -n "$NAMESPACE" "$pod" -- timeout 10 "$@" 2>&1
}

# 等待单个 Pod Ready
wait_pod_ready() {
    local pod="$1"
    local deadline=$((SECONDS + TIMEOUT))
    while [[ $SECONDS -lt $deadline ]]; do
        local phase
        phase=$(kc get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$phase" == "Running" ]]; then
            # 确认所有容器 Ready
            local ready
            ready=$(kc get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
            if [[ "$ready" == "True" ]]; then
                return 0
            fi
        fi
        sleep 2
    done
    log_warn "Pod $pod 未在 ${TIMEOUT}s 内就绪 (当前状态: $(kc get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Unknown'))"
    return 1
}

# 获取 Pod IP (默认网络)
get_pod_ip() {
    kc get pod -n "$NAMESPACE" "$1" -o jsonpath='{.status.podIP}' 2>/dev/null
}

# 获取 Pod 的 Multus 附加网络 IP
get_pod_multus_ip() {
    local pod="$1"
    local net_status
    net_status=$(kc get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' 2>/dev/null || echo "")
    if [[ -n "$net_status" ]]; then
        # 取第二个网络的 IP (index [1], 附加网络)
        echo "$net_status" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for net in data:
        if net.get('interface') != 'eth0':
            for ip in net.get('ips', []):
                print(ip)
                sys.exit(0)
except: pass
" 2>/dev/null || echo ""
    fi
}

# 获取节点列表
get_nodes() {
    kc get nodes -o jsonpath='{.items[*].metadata.name}'
}

# 获取节点 InternalIP
get_node_ip() {
    kc get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

# 获取 Pod 所在节点
get_pod_node() {
    kc get pod -n "$NAMESPACE" "$1" -o jsonpath='{.spec.nodeName}'
}

# ============================================================================
# 清理函数
# ============================================================================
cleanup() {
    if [[ "$SKIP_CLEANUP" == "true" ]]; then
        log_warn "跳过清理。资源保留在 namespace: $NAMESPACE"
        log_warn "手动清理: kubectl delete namespace $NAMESPACE"
        return
    fi
    log_section "清理测试资源"
    kc delete namespace "$NAMESPACE" --wait=false --ignore-not-found 2>/dev/null || true
    log_info "Namespace $NAMESPACE 已标记删除"
}

# ============================================================================
# 前置检查
# ============================================================================
preflight_check() {
    log_section "前置检查"

    # kubectl 可用
    if ! command -v kubectl &>/dev/null; then
        echo "错误: kubectl 未安装" >&2; exit 1
    fi
    log_info "kubectl 版本: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"

    # 集群连接
    if ! kc cluster-info &>/dev/null; then
        echo "错误: 无法连接到 Kubernetes 集群" >&2; exit 1
    fi
    log_info "集群连接正常"

    # 检测节点数
    local node_count
    node_count=$(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log_info "集群节点数: $node_count"
    if [[ "$node_count" -lt 2 ]]; then
        log_warn "集群只有 $node_count 个节点，跨节点测试将被跳过"
    fi

    # 检测 Multus 是否安装
    MULTUS_INSTALLED=false
    if kc get crd network-attachment-definitions.k8s.cni.cncf.io &>/dev/null; then
        MULTUS_INSTALLED=true
        log_info "Multus CNI: 已安装"
    else
        log_warn "Multus CNI: 未安装 — Spiderpool 相关测试将被跳过"
    fi

    # 检测 Spiderpool 是否安装
    SPIDERPOOL_INSTALLED=false
    if [[ "$MULTUS_INSTALLED" == "true" ]]; then
        if kc get crd spidersubnets.spiderpool.spidernet.io &>/dev/null 2>&1 || \
           kc get crd spiderippools.spiderpool.spidernet.io &>/dev/null 2>&1; then
            SPIDERPOOL_INSTALLED=true
            log_info "Spiderpool: 已安装"
        else
            log_warn "Spiderpool: 未检测到 — Spiderpool 相关测试将被跳过"
        fi
    fi

    # 检测 LoadBalancer 支持 (MetalLB / Cloud LB)
    LB_SUPPORTED=false
    if kc get crd ipaddresspools.metallb.io &>/dev/null 2>&1 || \
       kc get svc -A --field-selector spec.type=LoadBalancer -o jsonpath='{.items[0].status.loadBalancer.ingress[0]}' 2>/dev/null | grep -q .; then
        LB_SUPPORTED=true
        log_info "LoadBalancer: 可用"
    else
        log_warn "LoadBalancer: 未检测到 (MetalLB 等) — LB 测试将尝试执行但可能 pending"
    fi
}

# ============================================================================
# 创建测试资源
# ============================================================================
create_resources() {
    log_section "创建测试资源 (namespace: $NAMESPACE)"

    kc create namespace "$NAMESPACE"
    kc label namespace "$NAMESPACE" purpose=network-test --overwrite

    # ------------------------------------------------------------------
    # 获取调度节点 (尽量分布到不同节点)
    # ------------------------------------------------------------------
    local nodes
    read -r -a nodes <<< "$(get_nodes)"
    local node1="${nodes[0]}"
    local node2="${nodes[0]}"
    if [[ ${#nodes[@]} -ge 2 ]]; then
        node2="${nodes[1]}"
    fi
    log_info "调度节点: node1=$node1, node2=$node2"

    # ------------------------------------------------------------------
    # Type A: 默认 CNI Pod (分布在两个节点)
    # ------------------------------------------------------------------
    log_info "创建 Type A (默认 CNI) Pods..."
    for i in 1 2; do
        local target_node="$node1"
        [[ "$i" == "2" ]] && target_node="$node2"

        kc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pod-default-${i}
  labels:
    app: nettest
    cni-type: default
    instance: "pod-default-${i}"
spec:
  nodeName: ${target_node}
  containers:
  - name: netshoot
    image: ${IMAGE}
    command: ["sleep", "infinity"]
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 128Mi
  terminationGracePeriodSeconds: 3
EOF
    done

    # ------------------------------------------------------------------
    # Type B: Spiderpool 作为默认网络
    # ------------------------------------------------------------------
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        log_info "创建 Type B (Spiderpool 默认网络) Pods..."

        local spider_annotations="v1.multus-cni.io/default-network: ${SPIDERPOOL_DEFAULT_MULTUS}"
        if [[ -n "$SPIDERPOOL_SUBNET" ]]; then
            spider_annotations="${spider_annotations}
    ipam.spidernet.io/subnet: '{\"ipv4\":\"${SPIDERPOOL_SUBNET}\"}'"
        fi

        for i in 1 2; do
            local target_node="$node1"
            [[ "$i" == "2" ]] && target_node="$node2"

            kc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pod-spider-${i}
  labels:
    app: nettest
    cni-type: spiderpool
    instance: "pod-spider-${i}"
  annotations:
    ${spider_annotations}
spec:
  nodeName: ${target_node}
  containers:
  - name: netshoot
    image: ${IMAGE}
    command: ["sleep", "infinity"]
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 128Mi
  terminationGracePeriodSeconds: 3
EOF
        done
    fi

    # ------------------------------------------------------------------
    # Type C: 默认 CNI + Spiderpool 附加网络
    # ------------------------------------------------------------------
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        log_info "创建 Type C (默认 CNI + Spiderpool 附加) Pods..."

        local addl_annotations="k8s.v1.cni.cncf.io/networks: ${SPIDERPOOL_ADDITIONAL_MULTUS}"
        if [[ -n "$SPIDERPOOL_SUBNET" ]]; then
            addl_annotations="${addl_annotations}
    ipam.spidernet.io/subnet: '{\"ipv4\":\"${SPIDERPOOL_SUBNET}\"}'"
        fi

        for i in 1 2; do
            local target_node="$node1"
            [[ "$i" == "2" ]] && target_node="$node2"

            kc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pod-dual-${i}
  labels:
    app: nettest
    cni-type: dual
    instance: "pod-dual-${i}"
  annotations:
    ${addl_annotations}
spec:
  nodeName: ${target_node}
  containers:
  - name: netshoot
    image: ${IMAGE}
    command: ["sleep", "infinity"]
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 128Mi
  terminationGracePeriodSeconds: 3
EOF
        done
    fi

    # ------------------------------------------------------------------
    # HTTP 服务端 Pod + Services (用于 Service 测试)
    # ------------------------------------------------------------------
    log_info "创建 HTTP 服务端 Pod 和 Services..."
    kc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: http-server
  labels:
    app: http-server
    cni-type: default
spec:
  nodeName: ${node1}
  containers:
  - name: netshoot
    image: ${IMAGE}
    command:
    - sh
    - -c
    - |
      # 启动一个简单的 HTTP 服务
      while true; do
        echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nOK from \$(hostname) at \$(date)" | nc -l -p 8080 -w 1 || true
      done
    ports:
    - containerPort: 8080
      name: http
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 128Mi
  terminationGracePeriodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: svc-clusterip
spec:
  type: ClusterIP
  selector:
    app: http-server
  ports:
  - port: 80
    targetPort: 8080
    name: http
---
apiVersion: v1
kind: Service
metadata:
  name: svc-nodeport
spec:
  type: NodePort
  selector:
    app: http-server
  ports:
  - port: 80
    targetPort: 8080
    name: http
---
apiVersion: v1
kind: Service
metadata:
  name: svc-lb
spec:
  type: LoadBalancer
  selector:
    app: http-server
  ports:
  - port: 80
    targetPort: 8080
    name: http
EOF

    # ------------------------------------------------------------------
    # 如果 spiderpool 可用, 也创建 spiderpool 网络的 HTTP 服务端
    # ------------------------------------------------------------------
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        log_info "创建 Spiderpool 网络 HTTP 服务端..."

        local spider_svc_annotations="v1.multus-cni.io/default-network: ${SPIDERPOOL_DEFAULT_MULTUS}"
        if [[ -n "$SPIDERPOOL_SUBNET" ]]; then
            spider_svc_annotations="${spider_svc_annotations}
    ipam.spidernet.io/subnet: '{\"ipv4\":\"${SPIDERPOOL_SUBNET}\"}'"
        fi

        kc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: http-server-spider
  labels:
    app: http-server-spider
    cni-type: spiderpool
  annotations:
    ${spider_svc_annotations}
spec:
  nodeName: ${node1}
  containers:
  - name: netshoot
    image: ${IMAGE}
    command:
    - sh
    - -c
    - |
      while true; do
        echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nOK from \$(hostname) [spiderpool] at \$(date)" | nc -l -p 8080 -w 1 || true
      done
    ports:
    - containerPort: 8080
      name: http
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 128Mi
  terminationGracePeriodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: svc-clusterip-spider
spec:
  type: ClusterIP
  selector:
    app: http-server-spider
  ports:
  - port: 80
    targetPort: 8080
    name: http
EOF
    fi

    # ------------------------------------------------------------------
    # 等待所有 Pod 就绪
    # ------------------------------------------------------------------
    log_info "等待所有测试 Pod 就绪..."
    local all_pods
    all_pods=$(kc get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}')
    local failed_pods=()
    for pod in $all_pods; do
        log_info "  等待 $pod ..."
        if ! wait_pod_ready "$pod"; then
            failed_pods+=("$pod")
        fi
    done

    if [[ ${#failed_pods[@]} -gt 0 ]]; then
        log_warn "以下 Pod 未就绪，相关测试可能失败: ${failed_pods[*]}"
        log_info "Pod 状态详情:"
        kc get pods -n "$NAMESPACE" -o wide
        echo ""
        for fp in "${failed_pods[@]}"; do
            log_info "--- $fp events ---"
            kc describe pod -n "$NAMESPACE" "$fp" 2>/dev/null | tail -20
        done
    fi

    log_info "当前 Pod 状态:"
    kc get pods -n "$NAMESPACE" -o wide
    echo ""
    log_info "当前 Service 状态:"
    kc get svc -n "$NAMESPACE" -o wide
}

# ============================================================================
# 测试函数
# ============================================================================

# ---------- Pod → Pod (ping) ----------
test_pod_to_pod_ping() {
    local src="$1" dst="$2" desc="$3"
    local dst_ip
    dst_ip=$(get_pod_ip "$dst")
    if [[ -z "$dst_ip" ]]; then
        record_result skip "$desc (无法获取目标 IP)"
        return
    fi
    if exec_in_pod "$src" ping -c 2 -W 3 "$dst_ip" &>/dev/null; then
        record_result pass "$desc  [$src → $dst ($dst_ip)]"
    else
        record_result fail "$desc  [$src → $dst ($dst_ip)]"
    fi
}

# ---------- Pod → Pod via Multus IP (ping) ----------
test_pod_to_pod_multus_ping() {
    local src="$1" dst="$2" desc="$3"
    local dst_ip
    dst_ip=$(get_pod_multus_ip "$dst")
    if [[ -z "$dst_ip" ]]; then
        record_result skip "$desc (无法获取 Multus 附加网络 IP)"
        return
    fi
    if exec_in_pod "$src" ping -c 2 -W 3 "$dst_ip" &>/dev/null; then
        record_result pass "$desc  [$src → $dst multus-ip ($dst_ip)]"
    else
        record_result fail "$desc  [$src → $dst multus-ip ($dst_ip)]"
    fi
}

# ---------- Pod → Service (curl) ----------
test_pod_to_svc() {
    local src="$1" svc_addr="$2" desc="$3"
    if exec_in_pod "$src" curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${svc_addr}" 2>/dev/null | grep -q "200"; then
        record_result pass "$desc  [$src → $svc_addr]"
    else
        record_result fail "$desc  [$src → $svc_addr]"
    fi
}

# ---------- Pod → External (ping + curl) ----------
test_pod_to_external() {
    local src="$1" desc_prefix="$2"

    # ping 外部 IP
    if exec_in_pod "$src" ping -c 2 -W 3 "$TEST_EXTERNAL_IP" &>/dev/null; then
        record_result pass "${desc_prefix}: ping 外部 IP ($TEST_EXTERNAL_IP)"
    else
        record_result fail "${desc_prefix}: ping 外部 IP ($TEST_EXTERNAL_IP)"
    fi

    # DNS 解析 + curl 外部域名
    if exec_in_pod "$src" curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${TEST_EXTERNAL_HOST}" 2>/dev/null | grep -qE "200|301|302"; then
        record_result pass "${desc_prefix}: curl 外部域名 ($TEST_EXTERNAL_HOST)"
    else
        record_result fail "${desc_prefix}: curl 外部域名 ($TEST_EXTERNAL_HOST)"
    fi
}

# ---------- Pod → Kubernetes API Server ----------
test_pod_to_apiserver() {
    local src="$1" desc="$2"
    # 使用 ServiceAccount token 访问 /healthz
    if exec_in_pod "$src" sh -c 'curl -sk --connect-timeout 5 -o /dev/null -w "%{http_code}" https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/healthz' 2>/dev/null | grep -q "200"; then
        record_result pass "$desc"
    else
        # 也可能 403 (token 无权限), 但说明网络是通的
        local code
        code=$(exec_in_pod "$src" sh -c 'curl -sk --connect-timeout 5 -o /dev/null -w "%{http_code}" https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/healthz' 2>/dev/null || echo "000")
        if [[ "$code" =~ ^(200|401|403)$ ]]; then
            record_result pass "$desc (HTTP $code, 网络可达)"
        else
            record_result fail "$desc (HTTP $code)"
        fi
    fi
}

# ---------- Pod → CoreDNS 解析测试 ----------
test_pod_dns() {
    local src="$1" desc="$2"

    # 集群内 Service DNS
    if exec_in_pod "$src" nslookup "kubernetes.default.svc.cluster.local" &>/dev/null; then
        record_result pass "${desc}: 集群内 DNS (kubernetes.default)"
    else
        record_result fail "${desc}: 集群内 DNS (kubernetes.default)"
    fi

    # 外部域名 DNS
    if exec_in_pod "$src" nslookup "$TEST_EXTERNAL_HOST" &>/dev/null; then
        record_result pass "${desc}: 外部 DNS ($TEST_EXTERNAL_HOST)"
    else
        record_result fail "${desc}: 外部 DNS ($TEST_EXTERNAL_HOST)"
    fi
}

# ---------- Node → Pod (从节点上通过 ssh/debug 测试) ----------
test_node_to_pod() {
    local node="$1" pod="$2" desc="$3"
    local pod_ip
    pod_ip=$(get_pod_ip "$pod")
    if [[ -z "$pod_ip" ]]; then
        record_result skip "$desc (无法获取 Pod IP)"
        return
    fi

    # 使用 kubectl debug node 方式, 在节点上执行 ping
    # 兼容: 如果 debug node 不可用, 使用 nsenter 方式
    local result
    result=$(kc debug "node/${node}" --image="${IMAGE}" -q -- \
        sh -c "ping -c 2 -W 3 ${pod_ip} && echo __PING_OK__" 2>&1 || true)

    if echo "$result" | grep -q "__PING_OK__"; then
        record_result pass "$desc  [node:$node → $pod ($pod_ip)]"
    else
        # 备选: 尝试通过 hostNetwork Pod 测试
        log_info "  debug node 方式失败, 尝试 hostNetwork Pod 方式..."
        local hostnet_pod="hostnet-probe-$(echo "$node" | tr '.' '-')"
        kc run "$hostnet_pod" -n "$NAMESPACE" --image="$IMAGE" \
            --overrides="{\"spec\":{\"nodeName\":\"${node}\",\"hostNetwork\":true,\"containers\":[{\"name\":\"probe\",\"image\":\"${IMAGE}\",\"command\":[\"ping\",\"-c\",\"2\",\"-W\",\"3\",\"${pod_ip}\"]}],\"restartPolicy\":\"Never\"}}" \
            --restart=Never 2>/dev/null || true

        # 等待完成
        local deadline=$((SECONDS + 30))
        while [[ $SECONDS -lt $deadline ]]; do
            local phase
            phase=$(kc get pod -n "$NAMESPACE" "$hostnet_pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            if [[ "$phase" == "Succeeded" ]]; then
                record_result pass "$desc  [node:$node → $pod ($pod_ip)]"
                kc delete pod -n "$NAMESPACE" "$hostnet_pod" --ignore-not-found &>/dev/null || true
                return
            elif [[ "$phase" == "Failed" ]]; then
                break
            fi
            sleep 2
        done
        record_result fail "$desc  [node:$node → $pod ($pod_ip)]"
        kc delete pod -n "$NAMESPACE" "$hostnet_pod" --ignore-not-found &>/dev/null || true
    fi
}

# ============================================================================
# 主测试流程
# ============================================================================

run_pod_to_pod_tests() {
    log_section "测试 1: Pod → Pod 连通性"

    local nodes
    read -r -a nodes <<< "$(get_nodes)"
    local multi_node=false
    [[ ${#nodes[@]} -ge 2 ]] && multi_node=true

    # --- Type A: 默认 CNI ---
    log_info "--- Type A (默认 CNI) ---"
    test_pod_to_pod_ping "pod-default-1" "pod-default-2" \
        "[A→A] 默认CNI Pod 间 $(if $multi_node; then echo '(跨节点)'; else echo '(同节点)'; fi)"

    # --- Type B: Spiderpool 默认网络 ---
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        log_info "--- Type B (Spiderpool 默认网络) ---"
        test_pod_to_pod_ping "pod-spider-1" "pod-spider-2" \
            "[B→B] Spiderpool Pod 间 $(if $multi_node; then echo '(跨节点)'; else echo '(同节点)'; fi)"
    fi

    # --- Type C: 双网络 ---
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        log_info "--- Type C (默认 CNI + Spiderpool 附加) ---"
        # 通过默认网络
        test_pod_to_pod_ping "pod-dual-1" "pod-dual-2" \
            "[C→C] 双网络 Pod 间 - 默认网络 $(if $multi_node; then echo '(跨节点)'; else echo '(同节点)'; fi)"
        # 通过 Multus 附加网络
        test_pod_to_pod_multus_ping "pod-dual-1" "pod-dual-2" \
            "[C→C] 双网络 Pod 间 - Multus 附加网络 $(if $multi_node; then echo '(跨节点)'; else echo '(同节点)'; fi)"
    fi

    # --- 跨 CNI 类型互通 ---
    log_info "--- 跨 CNI 类型互通 ---"
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_pod_to_pod_ping "pod-default-1" "pod-spider-1" \
            "[A→B] 默认CNI → Spiderpool 默认网络"
        test_pod_to_pod_ping "pod-spider-1" "pod-default-1" \
            "[B→A] Spiderpool 默认网络 → 默认CNI"
        test_pod_to_pod_ping "pod-default-1" "pod-dual-1" \
            "[A→C] 默认CNI → 双网络 (默认网络)"
        test_pod_to_pod_ping "pod-dual-1" "pod-default-1" \
            "[C→A] 双网络 → 默认CNI"
        test_pod_to_pod_ping "pod-spider-1" "pod-dual-1" \
            "[B→C] Spiderpool → 双网络 (默认网络)"
        test_pod_to_pod_ping "pod-dual-1" "pod-spider-1" \
            "[C→B] 双网络 → Spiderpool"
    fi
}

run_pod_to_svc_tests() {
    log_section "测试 2: Pod → Service 连通性"

    local clusterip
    clusterip=$(kc get svc -n "$NAMESPACE" svc-clusterip -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    local nodeport
    nodeport=$(kc get svc -n "$NAMESPACE" svc-nodeport -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
    local lb_ip
    lb_ip=$(kc get svc -n "$NAMESPACE" svc-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

    local nodes
    read -r -a nodes <<< "$(get_nodes)"
    local node_ip
    node_ip=$(get_node_ip "${nodes[0]}")

    # 定义要测试的源 Pod 列表
    local src_pods=("pod-default-1")
    local src_labels=("TypeA-默认CNI")
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        src_pods+=("pod-spider-1" "pod-dual-1")
        src_labels+=("TypeB-Spiderpool" "TypeC-双网络")
    fi

    for idx in "${!src_pods[@]}"; do
        local src="${src_pods[$idx]}"
        local label="${src_labels[$idx]}"

        log_info "--- 源: ${label} (${src}) ---"

        # ClusterIP - by IP
        if [[ -n "$clusterip" ]]; then
            test_pod_to_svc "$src" "${clusterip}:80" \
                "[${label}] → ClusterIP ($clusterip:80)"
        fi

        # ClusterIP - by DNS name
        test_pod_to_svc "$src" "svc-clusterip.${NAMESPACE}.svc.cluster.local:80" \
            "[${label}] → ClusterIP (DNS: svc-clusterip)"

        # NodePort
        if [[ -n "$nodeport" && -n "$node_ip" ]]; then
            test_pod_to_svc "$src" "${node_ip}:${nodeport}" \
                "[${label}] → NodePort (${node_ip}:${nodeport})"
        else
            record_result skip "[${label}] → NodePort (无法获取 NodePort)"
        fi

        # LoadBalancer
        if [[ -n "$lb_ip" ]]; then
            test_pod_to_svc "$src" "${lb_ip}:80" \
                "[${label}] → LoadBalancer ($lb_ip:80)"
        else
            record_result skip "[${label}] → LoadBalancer (LB IP 未分配, 可能无 LB 控制器)"
        fi
    done

    # --- Spiderpool Service ---
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        log_info "--- Spiderpool 网络 Service ---"
        local spider_clusterip
        spider_clusterip=$(kc get svc -n "$NAMESPACE" svc-clusterip-spider -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
        if [[ -n "$spider_clusterip" ]]; then
            for idx in "${!src_pods[@]}"; do
                test_pod_to_svc "${src_pods[$idx]}" "${spider_clusterip}:80" \
                    "[${src_labels[$idx]}] → Spiderpool SVC ClusterIP ($spider_clusterip:80)"
            done
        fi
    fi
}

run_node_to_pod_tests() {
    log_section "测试 3: Node → Pod 连通性"

    local nodes
    read -r -a nodes <<< "$(get_nodes)"
    local node="${nodes[0]}"

    # Node → 默认 CNI Pod
    test_node_to_pod "$node" "pod-default-1" \
        "[Node→A] 节点 → 默认CNI Pod"

    # Node → Spiderpool Pod
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_node_to_pod "$node" "pod-spider-1" \
            "[Node→B] 节点 → Spiderpool Pod"
        test_node_to_pod "$node" "pod-dual-1" \
            "[Node→C] 节点 → 双网络 Pod"
    fi

    # 如果有第二个节点, 测试跨节点
    if [[ ${#nodes[@]} -ge 2 ]]; then
        local node2="${nodes[1]}"
        test_node_to_pod "$node2" "pod-default-1" \
            "[Node→A] 跨节点 → 默认CNI Pod"
        if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
            test_node_to_pod "$node2" "pod-spider-1" \
                "[Node→B] 跨节点 → Spiderpool Pod"
        fi
    fi
}

run_external_tests() {
    log_section "测试 4: Pod → 外部网络"

    test_pod_to_external "pod-default-1" "[TypeA-默认CNI]"

    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_pod_to_external "pod-spider-1" "[TypeB-Spiderpool]"
        test_pod_to_external "pod-dual-1"   "[TypeC-双网络]"
    fi
}

run_dns_tests() {
    log_section "测试 5: DNS 解析"

    test_pod_dns "pod-default-1" "[TypeA-默认CNI]"

    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_pod_dns "pod-spider-1" "[TypeB-Spiderpool]"
        test_pod_dns "pod-dual-1"   "[TypeC-双网络]"
    fi
}

run_apiserver_tests() {
    log_section "测试 6: Pod → Kubernetes API Server"

    test_pod_to_apiserver "pod-default-1" "[TypeA-默认CNI] → API Server"

    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_pod_to_apiserver "pod-spider-1" "[TypeB-Spiderpool] → API Server"
        test_pod_to_apiserver "pod-dual-1"   "[TypeC-双网络] → API Server"
    fi
}

run_same_node_cross_node_tests() {
    log_section "测试 7: 同节点 vs 跨节点对比 (TCP 连通)"

    local nodes
    read -r -a nodes <<< "$(get_nodes)"
    if [[ ${#nodes[@]} -lt 2 ]]; then
        record_result skip "跨节点测试: 集群节点不足 2 个"
        return
    fi

    # pod-default-1 和 http-server 在同一节点 (node1)
    log_info "--- 同节点 TCP ---"
    local server_ip
    server_ip=$(get_pod_ip "http-server")
    if [[ -n "$server_ip" ]]; then
        test_pod_to_svc "pod-default-1" "${server_ip}:8080" \
            "[同节点] pod-default-1 → http-server (直连 Pod IP)"
    fi

    # pod-default-2 在 node2, http-server 在 node1
    log_info "--- 跨节点 TCP ---"
    if [[ -n "$server_ip" ]]; then
        test_pod_to_svc "pod-default-2" "${server_ip}:8080" \
            "[跨节点] pod-default-2 → http-server (直连 Pod IP)"
    fi
}

run_mtu_test() {
    log_section "测试 8: MTU / 大包测试"

    local pods=("pod-default-1")
    local labels=("TypeA-默认CNI")
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        pods+=("pod-spider-1" "pod-dual-1")
        labels+=("TypeB-Spiderpool" "TypeC-双网络")
    fi

    local dst_ip
    dst_ip=$(get_pod_ip "pod-default-2")
    if [[ -z "$dst_ip" ]]; then
        record_result skip "MTU 测试: 无法获取目标 Pod IP"
        return
    fi

    for idx in "${!pods[@]}"; do
        local src="${pods[$idx]}"
        local label="${labels[$idx]}"

        # 1400 字节 (通常安全)
        if exec_in_pod "$src" ping -c 2 -W 5 -M do -s 1400 "$dst_ip" &>/dev/null; then
            record_result pass "[${label}] MTU 测试: 1400 字节 ping 成功"
        else
            record_result fail "[${label}] MTU 测试: 1400 字节 ping 失败 (MTU 可能过小)"
        fi

        # 探测实际 MTU
        local mtu_val=""
        for size in 1500 1450 1400 1350 1300 1200; do
            if exec_in_pod "$src" ping -c 1 -W 3 -M do -s "$size" "$dst_ip" &>/dev/null; then
                mtu_val=$((size + 28))  # ICMP header = 8, IP header = 20
                break
            fi
        done
        if [[ -n "$mtu_val" ]]; then
            log_info "  [${label}] 探测 MTU ≥ ${mtu_val} bytes"
        else
            log_warn "  [${label}] 无法探测 MTU (所有大小均失败)"
        fi
    done
}

run_hairpin_test() {
    log_section "测试 9: Hairpin / 自身访问测试"

    # Pod 通过 Service 访问自身 (hairpin NAT)
    log_info "--- Pod 通过 ClusterIP Service 访问自身 ---"
    test_pod_to_svc "http-server" "svc-clusterip.${NAMESPACE}.svc.cluster.local:80" \
        "[Hairpin] http-server → 自身 ClusterIP Service"
}

run_network_policy_test() {
    log_section "测试 10: NetworkPolicy 验证 (可选)"

    # 创建一个 NetworkPolicy 拒绝所有入站
    log_info "创建 deny-all NetworkPolicy..."
    kc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-to-isolated
spec:
  podSelector:
    matchLabels:
      instance: pod-default-2
  policyTypes:
  - Ingress
  ingress: []   # 拒绝所有入站
EOF

    sleep 3  # 等待策略生效

    local dst_ip
    dst_ip=$(get_pod_ip "pod-default-2")
    if [[ -z "$dst_ip" ]]; then
        record_result skip "NetworkPolicy 测试: 无法获取目标 IP"
        kc delete networkpolicy -n "$NAMESPACE" deny-all-to-isolated --ignore-not-found &>/dev/null
        return
    fi

    # 预期: ping 应该失败
    if ! exec_in_pod "pod-default-1" ping -c 2 -W 3 "$dst_ip" &>/dev/null; then
        record_result pass "[NetworkPolicy] deny-all 策略生效: ping 被拒绝"
    else
        record_result fail "[NetworkPolicy] deny-all 策略未生效: ping 仍然成功 (CNI 可能不支持 NetworkPolicy)"
    fi

    # 清理 NetworkPolicy
    kc delete networkpolicy -n "$NAMESPACE" deny-all-to-isolated --ignore-not-found &>/dev/null

    sleep 3  # 等待策略删除生效

    # 验证删除后恢复
    if exec_in_pod "pod-default-1" ping -c 2 -W 3 "$dst_ip" &>/dev/null; then
        record_result pass "[NetworkPolicy] 策略删除后恢复: ping 成功"
    else
        record_result fail "[NetworkPolicy] 策略删除后未恢复: ping 仍然失败"
    fi
}

# ============================================================================
# 打印报告
# ============================================================================
print_report() {
    log_section "测试报告"
    echo ""
    echo -e "  ${GREEN}通过${NC}: ${PASS_COUNT}"
    echo -e "  ${RED}失败${NC}: ${FAIL_COUNT}"
    echo -e "  ${CYAN}跳过${NC}: ${SKIP_COUNT}"
    echo -e "  ${BOLD}总计${NC}: ${TOTAL_COUNT}"
    echo ""

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "${RED}${BOLD}⚠ 存在失败的测试项, 请检查上方日志获取详情${NC}"
        echo ""
        echo "排查建议:"
        echo "  1. 检查 Pod 网络配置: kubectl get pods -n $NAMESPACE -o wide"
        echo "  2. 检查 Pod 日志/事件: kubectl describe pod <pod-name> -n $NAMESPACE"
        echo "  3. 检查 CNI 日志: journalctl -u kubelet | grep cni"
        echo "  4. 检查 Spiderpool 状态: kubectl get spiderippool -A"
        echo "  5. 检查 kube-proxy / iptables: iptables -t nat -L -n | grep <svc-clusterip>"
    else
        echo -e "${GREEN}${BOLD}✅ 所有测试通过!${NC}"
    fi
    echo ""
}

# ============================================================================
# 主入口
# ============================================================================
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     Kubernetes Multi-CNI Network Connectivity Test Suite    ║${NC}"
    echo -e "${BOLD}║     (Default CNI / Spiderpool / Dual-Network)              ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    trap cleanup EXIT

    preflight_check
    create_resources

    run_pod_to_pod_tests
    run_pod_to_svc_tests
    run_node_to_pod_tests
    run_external_tests
    run_dns_tests
    run_apiserver_tests
    run_same_node_cross_node_tests
    run_mtu_test
    run_hairpin_test
    run_network_policy_test

    print_report

    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
