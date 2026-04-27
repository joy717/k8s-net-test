# k8s-net-test

Kubernetes **多 CNI 网络连通性**全面验证脚本。一条命令在集群里部署一组测试 pod，覆盖 Pod↔Pod、Pod↔Service、Pod↔外部、DNS、API Server、MTU、Hairpin、NetworkPolicy 等 10 大类共 70+ 项检查，并产出**带分类汇总和智能排查建议**的报告。

特别针对 **Spiderpool (macvlan) + 默认 CNI (Calico/Cilium/...) + MetalLB** 这种"underlay + overlay 共存"的复杂环境优化，能识别同节点 / 跨节点路径差异，避免常见的误诊断。

---

## 特性

- **零依赖部署**：单个 bash 脚本，仅依赖 `kubectl`。镜像走公共代理（`m.daocloud.io/docker.io/nicolaka/netshoot`），离线环境改一行变量即可。
- **自适应跳过**：自动探测 Multus / Spiderpool / MetalLB / 多节点是否存在，没有则跳过对应测试，不会假报错。
- **三类 Pod 网络**：自动覆盖
  - Type A — 默认 CNI
  - Type B — Spiderpool 作为默认网络（macvlan）
  - Type C — 默认 CNI + Spiderpool 附加网络（双网卡）
- **同 / 跨节点路径都覆盖**：跨 CNI 互通、Service、TCP 等所有用例都同时测同节点和跨节点。
- **失败诊断**：每个失败项给 `reason` + 可复制粘贴的 `kubectl exec` **复现命令**。
- **智能排查建议**：按失败类型自动给针对性提示（macvlan + LB / spider→calico 跨节点 / 真 MTU / NetworkPolicy / DNS 等），并指向 [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) 中的真实案例。
- **可选择运行**：`--only` / `--skip` 灵活过滤测试集合。
- **完整自清理**：默认用完销毁所有资源；`--skip-cleanup` 保留现场便于排查。

---

## 快速开始

```bash
# 1. 拉脚本到任何能 kubectl 访问集群的机器
git clone https://github.com/joy717/k8s-net-test.git
cd k8s-net-test
chmod +x k8s-net-test.sh

# 2. 最简跑法（自动检测环境）
./k8s-net-test.sh

# 3. 指定 Spiderpool 的 NetworkAttachmentDefinition
./k8s-net-test.sh --spiderpool-multus "spiderpool/l2-ens4"
```

正常情况下你会看到类似：

```
  通过: 76 / 77
  失败: 0
  跳过: 1

按类目:
  ✓  Pod→Pod        16/16  pass
  ✓  Pod→SVC        25/25  pass
  ✓  Node→Pod       5/5    pass
  ✓  External       6/6    pass
  ✓  DNS            6/6    pass
  ✓  APIServer      3/3    pass
  ✓  Same/Cross     6/6    pass
  ✓  MTU            6/6    pass
  ✓  Hairpin        1/1    pass
  ✓  NetworkPolicy  2/3    pass  1 skip

✅ 所有测试通过!
```

---

## 命令行参数

```
--namespace <ns>            指定测试 namespace（默认 net-test-<timestamp>）
--skip-cleanup              跑完后保留资源（便于排查），默认会自动删
--timeout <seconds>         等待 Pod Ready 的超时时间（默认 120）
--spiderpool-subnet <name>  指定 Spiderpool 子网（用于 IPAM 注入）
--spiderpool-multus <name>  Spiderpool NAD 名称（如 "spiderpool/l2-ens4"）
--kubeconfig <path>         指定 kubeconfig 文件
--verbose / -v              开启详细输出（失败时直接打印命令输出）
--only <name1,name2>        只跑指定测试（逗号分隔）
--skip <name1,name2>        跳过指定测试
-h / --help                 显示帮助
```

`--only` / `--skip` 支持的测试名：

| 名称 | 测试内容 |
|---|---|
| `pod2pod`       | Pod → Pod (同节点 + 跨节点 + 跨 CNI 互通) |
| `pod2svc`       | Pod → Service (ClusterIP / NodePort / LoadBalancer) |
| `node2pod`      | 节点 → Pod (本节点 + 跨节点) |
| `external`      | Pod → 外部 IP / 域名 |
| `dns`           | 集群内 DNS + 外部 DNS |
| `apiserver`     | Pod → kube-apiserver `/healthz` |
| `samenode`      | 同 / 跨节点直连 Pod IP TCP 对比 |
| `mtu`           | MTU 大包测试（先做连通性检查再测 MTU） |
| `hairpin`       | Pod 通过自身 Service 访问自身 |
| `networkpolicy` | NetworkPolicy 生效 / 解除验证 |

### 常用组合

```bash
# 只跑核心连通性，不动外网和 NetworkPolicy
./k8s-net-test.sh --only pod2pod,pod2svc,dns

# 跳过外网测试（离线 / 内网集群）
./k8s-net-test.sh --skip external,dns

# 留下资源排查
./k8s-net-test.sh --skip-cleanup --verbose

# 指定 spiderpool 配置 + verbose
./k8s-net-test.sh --spiderpool-multus "spiderpool/l2-ens4" --verbose
```

---

## 测试覆盖矩阵

### 1. Pod → Pod (16 项 @ 多节点 + Spiderpool)

|  | 同节点 | 跨节点 |
|---|---|---|
| A→A 默认 CNI | – | ✓ |
| B→B Spiderpool | – | ✓ |
| C→C 双网络（默认接口） | – | ✓ |
| C→C 双网络（Multus 附加接口） | – | ✓ |
| **A↔B / A↔C / B↔C 跨 CNI 互通** | ✓ × 6 | ✓ × 6 |

> ⚠️ 改进前所有跨 CNI 互通**只测同节点**，掩盖了 spider→calico 跨节点不通的问题。改进后必测两组。

### 2. Pod → Service (25 项)

源 Pod (5 个：A/B/C 在 node1 + B/C 在 node2) × Service 类型 (ClusterIP-IP / ClusterIP-DNS / NodePort / LoadBalancer / Spiderpool ClusterIP)。

> ⚠️ LB 测试覆盖 node1 和 node2 两侧的 spider/dual 源 pod，避免"只测某侧"漏掉 macvlan + 同节点 LB VIP 这种坑。

### 3. MTU (6 项)

源 (A/B/C 各 1) × 目标 (跨节点 default / 跨节点 spider)。

每项做两步：
1. **小包连通性检查** — 不通直接标"连通性失败 (非 MTU 问题)"
2. **1400 字节 DF ping** — 失败标"真 MTU 问题"

> ⚠️ 改进前直接用 1400 DF ping 判断成功，导致连通性挂的时候被误诊为 "MTU 过小"，浪费几小时排查时间。

### 4. NetworkPolicy (2 + 1 项)

- 默认 CNI：deny-all 必须生效，恢复后必须能通（FAIL 严格判定）
- Spiderpool macvlan：测试不生效是**预期**，标 SKIP + WARN（macvlan 流量绕过 host 协议栈，是已知限制）

---

## 失败时的输出样例

```
失败项详情:

  1. [pod2pod] [B→A] Spiderpool → 默认CNI [cross-node] [pod-spider-1 → pod-default-2 (10.233.86.32)]
       reason: 100% packet loss
       repro:  kubectl exec -n net-test-xxx pod-spider-1 -- ping -c 2 -W 3 10.233.86.32

排查建议:

  ⚠ 检测到 Spiderpool → Calico 跨节点失败
    可能原因: macvlan + Calico 不对称路径 (这次踩坑的典型问题)
    解决方案: 在每个节点添加 SNAT 规则:
      iptables -t nat -I POSTROUTING 1 \
        -s <SPIDER_CIDR> -d <CALICO_CIDR> -j MASQUERADE \
        -m comment --comment 'spiderpool-to-calico-snat'
    详见: TROUBLESHOOTING.md 问题 2

  完整排查文档: TROUBLESHOOTING.md (含真实案例、抓包技巧、修复脚本)
```

直接复制 `repro` 那行就能本地复现，不必再翻历史。

---

## 自适应行为

| 检测项 | 缺失时的行为 |
|---|---|
| `kubectl` | 直接退出 |
| 集群连接 | 直接退出 |
| 节点数 < 2 | 自动跳过所有跨节点用例（不报错） |
| Multus CRD | Spiderpool 全部测试跳过 |
| Spiderpool CRD | Type B / C 跳过，跨 CNI 测试跳过 |
| MetalLB 或已有 LB Service | 没有时 LB 测试 SKIP，提示"LB IP 未分配" |
| Pod 调度失败 | 给出 `kubectl describe` 提示 |

---

## 故障排查

遇到失败先看：

1. **报告底部的"排查建议"** — 脚本根据失败类型自动给针对性提示
2. **每个失败项的 `repro` 命令** — 直接复制粘贴本地复现
3. **[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)** — 真实环境踩坑记录，包含：
   - **问题 1**：pod-spider 访问本节点 LoadBalancer 不通
     - 根因：macvlan 父子接口本机通信限制 + Spiderpool `hijackCIDR` 未包含 LB VIP
     - 修复：把 LB VIP 加入 SpiderCoordinator
   - **问题 2**：pod-spider 跨节点访问 Calico pod 不通
     - 根因：不对称路径（请求走 VXLAN、回包走 ens4 二层）+ c-1 主路由把 spider IP 当本子网直连
     - 修复：所有节点加 `iptables MASQUERADE` SNAT 规则
   - **关键诊断技巧汇总**：iptables TRACE / 多接口分段抓包 / RPF 检查 / macvlan 模式确认 / conntrack 查询

---

## 工作原理

```
┌─────────────────────── namespace: net-test-<ts> ─────────────────────────┐
│                                                                          │
│  Type A (默认 CNI)        Type B (Spiderpool)      Type C (双网络)        │
│  pod-default-1 [node1]    pod-spider-1 [node1]     pod-dual-1 [node1]    │
│  pod-default-2 [node2]    pod-spider-2 [node2]     pod-dual-2 [node2]    │
│                                                                          │
│  HTTP 服务端                                                              │
│  http-server          [node1, Calico pod]                                │
│  http-server-spider   [node1, Spiderpool pod]                            │
│                                                                          │
│  Services                                                                │
│  svc-clusterip          (ClusterIP   → http-server)                      │
│  svc-nodeport           (NodePort    → http-server)                      │
│  svc-lb                 (LoadBalancer → http-server)                     │
│  svc-clusterip-spider   (ClusterIP   → http-server-spider)               │
└──────────────────────────────────────────────────────────────────────────┘
```

测试 pod 用 `nicolaka/netshoot` 镜像，自带 `ping`/`curl`/`nslookup`/`traceroute`/`tcpdump`/`mtr`/`iperf3` 等工具，便于失败时进 pod 手动排查。

---

## 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 全部通过 |
| `1` | 有失败项（CI 中可直接据此判断） |
| `>1` | 前置检查失败 / kubectl 不可用 |

---

## 适用场景

- 集群上线前的网络冒烟测试
- CNI 升级 / 切换后的回归验证
- 排查 "某些 pod 之间不通" 时快速定位是哪类路径出问题
- CI 流水线中的网络健康检查

---

## 维护

- 仓库：https://github.com/joy717/k8s-net-test
- 问题与改进建议：欢迎提 issue / PR
- 真实排查案例集：见 [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
