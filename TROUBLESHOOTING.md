# Spiderpool + Calico + MetalLB 网络互通问题排查记录

本文档记录在 ZStack Edge 测试集群上运行 `k8s-net-test.sh` 时遇到的两个真实问题，以及完整的排查过程、根因分析与修复方案。供后续遇到类似环境时参考。

---

## 测试环境

| 项 | 配置 |
|---|---|
| 集群 | 3 节点 (c-1/c-2/c-3，全部 control-plane + node) |
| OS | Kylin Linux Advanced Server V10 (Halberd), Kernel 4.19.90 |
| K8s | v1.35.1, 容器运行时 containerd 2.2.1 |
| 默认 CNI | Calico (VXLAN 模式, IP Pool `10.233.64.0/18`, `natOutgoing: true`) |
| 第二网络 | Spiderpool + Multus，macvlan bridge 模式，父接口 `ens4`，IP 段 `172.31.13.0/24` |
| LoadBalancer | MetalLB L2 模式，IP Pool `172.31.13.27-172.31.13.27`（与 spider pod 同子网） |
| 节点物理网卡 | `ens3` (集群网络 `172.27.211.0/24`)、`ens4` (业务/spider 网络 `172.31.13.0/24`) |

测试 namespace 由脚本动态创建（如 `net-test-1777018412`），里面含 8 个 pod：

- Type A：Calico pod (`pod-default-1` 在 c-1，`pod-default-2` 在 c-2)
- Type B：Spiderpool macvlan pod (`pod-spider-1` 在 c-1，`pod-spider-2` 在 c-2)
- Type C：双网络 pod，默认 Calico + 附加 Spiderpool (`pod-dual-1`/`pod-dual-2`)
- 服务端：`http-server` (Calico)、`http-server-spider` (Spiderpool)
- Service：`svc-clusterip` / `svc-nodeport` / `svc-lb` (LoadBalancer) / `svc-clusterip-spider`

---

## 问题 1：pod-spider-1 访问本节点 LoadBalancer 不通

### 现象

脚本测试 `[TypeB-Spiderpool] → LoadBalancer (172.31.13.27:80)` 报 FAIL。

具体表现：
- `pod-spider-1` (c-1, macvlan) → `svc-lb` (`172.31.13.27:80`)：❌ 不通
- `pod-spider-2` (c-2, macvlan) → 同一个 LB：✅ 通
- `pod-default-1` (c-1, Calico) → 同一个 LB：✅ 通
- `pod-spider-1` → c-1 自己的 ens4 IP `172.31.13.28`：✅ 通（Spiderpool 注入了 veth0 路由）
- `pod-spider-1` → c-2 的 ens4 IP `172.31.13.26`：✅ 通（macvlan 二层）

### 排查过程

**1. 确定 VIP 持有者**

```bash
# 在每个节点 ARP 查 VIP 172.31.13.27 的 MAC
arping -I ens4 -c 2 172.31.13.27
```

结果：返回 MAC `FA:AA:48:4A:F0:01`，正是 **c-1 节点 ens4 的 MAC**。说明 MetalLB speaker 把 VIP 通告到了 c-1 上。

**2. 查 pod 内路由**

```bash
kubectl exec pod-spider-1 -- ip r
# default via 172.31.13.1 dev eth0
# 10.233.0.0/18 via 172.31.13.28 dev veth0  src 172.31.13.29   ← Spiderpool 注入
# 172.27.211.18 dev veth0 ...                                  ← Spiderpool 注入 nodeIP
# 172.31.13.0/24 dev eth0 proto kernel scope link
# 172.31.13.28 dev veth0 ...                                    ← Spiderpool 注入本节点 ens4
```

```bash
kubectl exec pod-spider-1 -- ip r get 172.31.13.27
# 172.31.13.27 dev eth0 src 172.31.13.29     ← 走的是 macvlan，不是 veth0！
```

**3. macvlan 父子接口通信限制**

`pod-spider-1` 的 `eth0` 是 macvlan 子设备，父接口是 c-1 的 `ens4`。Linux macvlan 默认不允许 child ↔ parent **本机**直接通信。

VIP `172.31.13.27` 通告在 c-1 的 ens4（即 macvlan 父接口）上，对应 `kube-ipvs0` 上的 `172.31.13.27/32`。pod 把请求从 macvlan 子设备发给"本机父接口的 VIP"，**被 macvlan 同节点限制吃掉**。

跨节点的 spider pod (c-2) 发包到 LB VIP 时，包走 ens4 二层 → c-1 ens4 → kube-ipvs0 → DNAT，绕开了 macvlan 同机限制，所以通。

### 根因

> **macvlan pod 访问"本节点持有的 LB VIP"时，因 macvlan 父子接口本机通信限制被丢弃。Spiderpool 的 `hijackCIDR` 未包含 LB VIP，所以 pod 路由表把 VIP 当作 macvlan 子网直连地址，没有走 veth0 绕回 host 协议栈。**

### 修复

把 MetalLB 分配的 LB VIP 加入 `SpiderCoordinator` 的 `hijackCIDR`，让 Spiderpool 在 pod 创建时把这个 VIP 的下一跳改成 veth0，绕到 host 的 kube-ipvs0 处理。

```bash
kubectl patch spidercoordinator default --type='json' \
  -p='[{"op":"replace","path":"/spec/hijackCIDR",
        "value":["169.254.0.0/16","172.31.13.27/32"]}]'
```

修改后 spider pod 的路由表会出现：

```
172.31.13.27 via 172.31.13.28 dev veth0 src 172.31.13.29
```

⚠️ **`hijackCIDR` 只对新建的 pod 生效**。已存在的 pod 必须重建：

```bash
kubectl delete namespace net-test-1777018412
# 然后让 deployment / 测试脚本重新创建 pod
```

### 验证

```bash
kubectl exec pod-spider-1 -- curl -s -m 5 http://172.31.13.27
# OK from http-server at ...
```

### 一般化

如果 MetalLB 的 IP Pool 会扩展，建议把整个 LB 分配段都加入 `hijackCIDR`（例如 `172.31.13.16/28` 而非单个 `/32`），免得每次新增 LB IP 都要改配置。

---

## 问题 2：pod-spider-1 → 跨节点 Calico pod 完全不通

### 现象

脚本 `测试 8: MTU / 大包测试` 报 FAIL：

```
[FAIL] [TypeB-Spiderpool] MTU 测试: 1400 字节 ping 失败
[WARN] [TypeB-Spiderpool] 无法探测 MTU (所有大小均失败)
```

进一步测试发现这其实**不是 MTU 问题**——`pod-spider-1` 访问跨节点 Calico pod 时**任何包大小都不通**：

| 源 → 目标 | 结果 |
|---|---|
| pod-spider-1 (c-1) → pod-default-1 (c-1, 同节点 Calico) | ✅ 通 |
| pod-spider-1 (c-1) → pod-default-2 (c-2, 跨节点 Calico) | ❌ 全部丢 |
| pod-default-2 (c-2, Calico) → pod-spider-1 (c-1, macvlan) | ✅ 通（反向通） |

注意问题是**非对称的**：反向通，正向不通。

测试 1（Pod→Pod 互通）能通过的原因是脚本里 `[B→A]` 用的是 `pod-default-1`（同节点），所以掩盖了跨节点问题。MTU 测试用的 `pod-default-2`（跨节点）才暴露出来。

### 排查过程

**1. 确认请求被发出**

```
# c-1 vxlan.calico 入口抓包：spider 包进入 vxlan.calico 准备封装
17:23:04.444781 IP 172.31.13.29 > 10.233.86.32: ICMP echo request
```

**2. 确认 VXLAN 封装并发出 ens3**

```
# c-1 ens3 抓 udp/4789：VXLAN 包确实发到 c-2
172.27.211.18.47031 > 172.27.211.19.4789: VXLAN, vni 4096
  IP 172.31.13.29 > 10.233.86.32: ICMP echo request
```

源 IP 是 spider pod 的 `172.31.13.29`，**没有 SNAT**。

**3. 确认 c-2 收到并转发**

在 c-2 上 `iptables TRACE`：

```
TRACE: raw:PREROUTING IN=vxlan.calico SRC=172.31.13.29 DST=10.233.86.32
... 完整通过 cali-FORWARD ...
TRACE: filter:FORWARD ... OUT=cali0d416f8e3af ...
TRACE: mangle:POSTROUTING ... OUT=cali0d416f8e3af ...
```

包到达 pod-default-2 的 cali veth。

**4. 确认 pod-default-2 回了 reply**

```
# c-2 cali0d416f8e3af 抓包
17:33:25 IP 172.31.13.29 > 10.233.86.32: ICMP echo request
17:33:25 IP 10.233.86.32 > 172.31.13.29: ICMP echo reply  ← 回了！
```

**5. 看 c-2 上 reply 的回程**

```bash
# c-2 上对 spider IP 的路由
ip route get 172.31.13.29
# 172.31.13.29 dev ens4 src 172.31.13.26   ← 走 ens4 二层直连，不走 VXLAN！
```

```
# c-2 ens4 抓包：reply 通过 ens4 直接发出
17:33:59 IP 10.233.86.32 > 172.31.13.29: ICMP echo reply
```

**6. 看 c-1 是否收到 reply**

```
# c-1 ens4 抓包：reply 已到达
17:34:17 IP 10.233.86.32 > 172.31.13.29: ICMP echo reply
```

**7. 但 spider pod 没收到**

```bash
# pod 内
kubectl exec pod-spider-1 -- ping ...
# 100% packet loss
```

reply 在 c-1 ens4 收到后，没有送到 macvlan 子接口（spider pod 的 eth0）。

**8. 分析 c-1 上的路由判定**

```bash
# c-1 主路由表
ip route get 172.31.13.29
# 172.31.13.29 dev veth238cf125d64 table 500 src 172.27.211.18
```

c-1 上对 spider IP 的路由**只在 table 500 (Spiderpool hostRuleTable) 里**，主路由表没有专门条目。主路由表里 `172.31.13.0/24 dev ens4` 把整段当作直连子网。

当 c-1 ens4 从外部收到目标为 `172.31.13.29` 的包时，因为：
- 主路由表把它当作"本子网直连"，但本机 ens4 上没有 `.29` 这个 IP
- macvlan 在 bridge 模式下，**ens4 父接口收到的包不会自动转发到 macvlan 子设备的 netns**
- table 500 的策略只对**出方向**的源 IP 路由生效，对入方向的包不查

最终包被 c-1 host drop（既不是本机的也不能转发）。

### 根因

> **不对称路径 + macvlan 父接口收包不转给子设备：**
> 1. spider pod 出方向：通过 Spiderpool 注入的 `10.233.0.0/18 via veth0` 路由到 host，host 经 vxlan.calico 把包**保留源 IP 172.31.13.29** 封装 VXLAN 发到目标节点
> 2. Calico pod 回包：c-2 host 查 `172.31.13.29` 的路由命中 `dev ens4`（spider 子网二层直连）→ **回包不走 VXLAN，走 ens4 二层直接送 c-1**
> 3. c-1 ens4 收到 reply：主路由表判定 spider IP 属于本节点 ens4 直连子网，但本机没这个 IP，又**不会 forward 给 macvlan 子设备**（macvlan 父接口收包不会自动 demux 到子接口的 netns）→ **drop**

这是 Spiderpool macvlan + Calico VXLAN 同时存在 + 两套 IP 段在同一个二层子网时的典型不对称路径问题。

### 修复

在每个节点的 host 上对 spider IP → Calico Pool 的出方向流量做 SNAT，把源 IP 改成节点 IP。这样回包走 Calico 的 VXLAN 正常路径，conntrack 自动反向 NAT 送回 spider pod。

```bash
# 在每个节点执行
iptables -t nat -I POSTROUTING 1 \
  -s 172.31.13.0/24 -d 10.233.64.0/18 \
  -j MASQUERADE \
  -m comment --comment 'spiderpool-to-calico-snat'
```

参数解释：
- `-s 172.31.13.0/24`：Spiderpool 的 IP 段
- `-d 10.233.64.0/18`：Calico IP Pool（来自 `kubectl get ippool default-pool -o yaml`）
- `-j MASQUERADE`：自动用出接口 IP 做 SNAT
- 插入到 POSTROUTING **第 1 位**，确保在 Calico/Kube 自己的规则之前匹配

### 验证

```bash
kubectl exec pod-spider-1 -- ping -c 3 -W 1 -M do -s 1400 10.233.86.32
# 3 packets transmitted, 3 received, 0% packet loss
```

完整测试脚本：

```
通过: 53
失败: 0
跳过: 0
✅ 所有测试通过！
```

### 持久化

`iptables` 规则在节点重启后会丢失。生产环境需要至少一种持久化方案：

#### 方案 A：iptables-services 持久化（最简单）

```bash
# RHEL/Kylin 等
iptables-save > /etc/sysconfig/iptables
systemctl enable iptables
```

⚠️ 这种方式的缺点：与 kube-proxy / calico-node 在启动时刷规则有竞争风险。

#### 方案 B：DaemonSet 在每个节点保证规则存在（推荐）

部署一个特权 DaemonSet，启动时和定期检查时确保规则存在。骨架：

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: spiderpool-calico-snat
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: spiderpool-calico-snat
  template:
    metadata:
      labels:
        app: spiderpool-calico-snat
    spec:
      hostNetwork: true
      tolerations:
      - operator: Exists
      containers:
      - name: agent
        image: alpine:3.20
        securityContext:
          privileged: true
        command:
        - sh
        - -c
        - |
          apk add --no-cache iptables >/dev/null
          while true; do
            if ! iptables -t nat -C POSTROUTING \
                -s 172.31.13.0/24 -d 10.233.64.0/18 -j MASQUERADE \
                -m comment --comment 'spiderpool-to-calico-snat' 2>/dev/null; then
              iptables -t nat -I POSTROUTING 1 \
                -s 172.31.13.0/24 -d 10.233.64.0/18 -j MASQUERADE \
                -m comment --comment 'spiderpool-to-calico-snat'
              echo "$(date) inserted rule"
            fi
            sleep 60
          done
```

#### 方案 C：上游修复

向 Spiderpool 提交特性请求，让 SpiderCoordinator 支持类似 `snatToPodCIDR` 的字段，自动处理跨 CNI 的不对称路径。这是最彻底的方案。

---

## 关键诊断技巧汇总

下次遇到类似 macvlan + overlay CNI 共存的怪异网络问题时，按这个顺序排查可以快速定位：

### 1. 确认问题对称性

```bash
# A → B 不通时，先测 B → A 是否通
kubectl exec POD_A -- ping POD_B_IP
kubectl exec POD_B -- ping POD_A_IP
```

如果一边通一边不通，几乎肯定是不对称路径 / NAT / RPF / macvlan 父子限制之一。

### 2. 路由查询

```bash
# 在每个相关节点上查目标 IP 的路由
ip route get TARGET_IP                           # 主路由表
ip route get TARGET_IP from SRC_IP iif IFACE     # 入方向反查路由
ip rule show                                     # 看是否有策略路由
ip route show table 500                          # spiderpool hostRuleTable
```

特别注意 **正反路径用的接口是否一致**。

### 3. 接口间 ARP 验证（macvlan 场景必查）

```bash
arping -I ens4 -c 2 TARGET_IP
```

确定哪个节点持有/响应某个 IP。macvlan 子设备的 IP 是否能被父接口所在的"二层子网"上其他节点 ARP 到。

### 4. iptables TRACE（最强武器）

```bash
# 在 raw 表 PREROUTING 头插一条 TRACE 规则（注意范围要小）
iptables -t raw -I PREROUTING -s SRC_IP -j TRACE

# 触发流量后
dmesg | grep TRACE
journalctl --since '30 seconds ago' | grep TRACE

# 用完务必删掉，TRACE 性能开销大
iptables -t raw -D PREROUTING -s SRC_IP -j TRACE
```

TRACE 会输出包经过的**每一条 iptables 规则**，能精确看到包从哪个接口进、走到哪一步、被哪条规则放行/drop。同时还能区分包是走了 PREROUTING→FORWARD（转发）还是 PREROUTING→INPUT（本机入）。

### 5. 各跳分别抓包

```bash
# 源节点 pod veth
tcpdump -i vethXXX -nn icmp

# 源节点上行物理接口 (Calico VXLAN 外层)
tcpdump -i ens3 -nn 'udp port 4789' -vv

# 目标节点 vxlan.calico (VXLAN 解封后)
tcpdump -i vxlan.calico -nn icmp

# 目标 pod 的 cali veth（Calico）
tcpdump -i cali0xxx -nn icmp

# 回程关键：是不是走了和正向不一样的接口？
tcpdump -i ens4 -nn icmp     # 直连 L2 回程
```

逐跳定位丢包发生在哪一段。

### 6. 接口 drop 统计

```bash
ip -s -s link show vxlan.calico
ip -s -s link show ens4
ethtool -S ens3 | grep -i drop
cat /proc/net/snmp | grep -A1 '^Udp:'
```

### 7. conntrack 状态

```bash
# 观察连接是否被记录、是否 [UNREPLIED]
conntrack -L -p icmp 2>&1 | grep TARGET_IP
```

`[UNREPLIED]` 说明请求发出去了但没收到回复，反向路径出问题。

### 8. rp_filter 检查

```bash
for i in all default ens3 ens4 vxlan.calico; do
  echo -n "$i: "
  cat /proc/sys/net/ipv4/conf/$i/rp_filter
done
```

不对称路径下 rp_filter=1 会触发 RPF drop。临时关闭测试：

```bash
echo 0 > /proc/sys/net/ipv4/conf/IFACE/rp_filter
```

### 9. macvlan 模式确认

```bash
nsenter -t POD_PID -n ip -d link show eth0
# 看输出里的 macvlan mode bridge / private / vepa
```

`bridge` 模式：同 master 的 macvlan 子设备之间能通，但仍**不能与 master 父接口本机通信**。这是经常踩坑的点。

---

## 教训与建议

1. **MTU 测试失败 ≠ MTU 问题**。先测小包是否通，确认是真 MTU 还是连通性问题被误诊断。脚本里 `MTU 测试: 1400 字节 ping 失败` 实际上是连通性 0%，应该单独标记区分。

2. **测试脚本的"跨 CNI 互通"用例要明确覆盖跨节点**。当前 `[B→A]` 用 `pod-default-1`（同节点）容易掩盖跨节点问题。建议改为同时测同节点和跨节点。

3. **Spiderpool macvlan + Calico VXLAN 这种"双 CNI 同子网"组合需要额外的 SNAT 规则**，否则跨 CNI 跨节点流量必丢。这一点 Spiderpool 文档没有充分提示，部署时要特别注意。

4. **MetalLB IP Pool 和 macvlan IP 段同子网时，pod 访问本节点 LB VIP 必失败**，需要 `hijackCIDR`。如果可能，**给 LB 分配独立的 IP 段**（不同 L2/L3）能从根本上避免这个问题。

5. **iptables TRACE 是双 CNI 场景的杀手锏**。先 TRACE，再抓包，效率比反过来高很多。

6. **`hijackCIDR` 改完一定要重建 pod**，否则配置不生效。

---

## 附：本次涉及的关键命令速查

```bash
# 修复 1：LB VIP 加入 hijackCIDR
kubectl patch spidercoordinator default --type='json' \
  -p='[{"op":"replace","path":"/spec/hijackCIDR",
        "value":["169.254.0.0/16","172.31.13.27/32"]}]'

# 修复 2：所有节点添加 SNAT 规则
for ip in 172.27.211.18 172.27.211.19 172.27.211.20; do
  ssh root@$ip "
    iptables -t nat -C POSTROUTING \
      -s 172.31.13.0/24 -d 10.233.64.0/18 -j MASQUERADE \
      -m comment --comment 'spiderpool-to-calico-snat' 2>/dev/null \
    || iptables -t nat -I POSTROUTING 1 \
      -s 172.31.13.0/24 -d 10.233.64.0/18 -j MASQUERADE \
      -m comment --comment 'spiderpool-to-calico-snat'
  "
done

# 重跑测试验证
bash k8s-net-test.sh --spiderpool-multus 'spiderpool/l2-ens4'
```
