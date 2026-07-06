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
#   7. NetworkPolicy 连通性 (Ingress + Egress, 如启用)
#   8. 多后端 Service 黑洞检测 (部分后端不可达导致的间歇性超时)
#
# 使用方式:
#   chmod +x k8s-net-test.sh
#   ./k8s-net-test.sh [--namespace <ns>] [--skip-cleanup] [--timeout <seconds>]
#                     [--spiderpool-subnet <name>] [--spiderpool-multus <name>]
#                     [--kubeconfig <path>] [--verbose] [--skip-lb]
#                     [--image <image>]
#                     [--only <name1,name2>] [--skip <name1,name2>]
#
# 测试名称 (用于 --only / --skip):
#   pod2pod, pod2svc, multibackend, node2pod, external, dns, apiserver,
#   samenode, mtu, hairpin, networkpolicy
#
# 排查记录 (失败时建议查看):
#   TROUBLESHOOTING.md  — 已知问题、根因和修复方案

# bash >= 4.4 硬性要求: declare -A 需要 4.0+; set -u 下空数组展开 ("${arr[@]}") 需要 4.4+
# macOS 自带 bash 3.2 会在 declare -A 处报一句莫名其妙的错后死掉, 这里提前给出明确提示
if [[ -z "${BASH_VERSINFO:-}" || ${BASH_VERSINFO[0]} -lt 4 || ( ${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -lt 4 ) ]]; then
    echo "错误: 需要 bash >= 4.4 (当前: ${BASH_VERSION:-unknown})。macOS 请 brew install bash 后用新 bash 运行" >&2
    exit 2
fi

# -E (errtrace): ERR trap 需要被函数继承, 否则 on_unexpected_error 对函数内失败不生效
set -Eeuo pipefail

# ============================================================================
# 配置
# ============================================================================
NAMESPACE="net-test-$(date +%s)"
# pin 版本保证长期可复现 (nc/shell 行为漂移会弄坏伪 HTTP server); 需要升级用 --image 覆盖
IMAGE="m.daocloud.io/docker.io/nicolaka/netshoot:v0.16"
TIMEOUT=120          # 等待 Pod Ready 的超时时间 (秒)
SKIP_CLEANUP=false
TEST_EXTERNAL_HOST="www.baidu.com"
TEST_EXTERNAL_IP="223.5.5.5"  # 阿里 DNS, 用于测试外部连通性

# Spiderpool / Multus 相关配置
SPIDERPOOL_DEFAULT_MULTUS="spiderpool/l2-ens4"    # Type B: spiderpool 作为默认网络
SPIDERPOOL_ADDITIONAL_MULTUS="spiderpool/l2-ens4"  # Type C: spiderpool 作为附加网络
SPIDERPOOL_SUBNET=""  # 可选: 指定 spiderpool subnet 名称

KUBECONFIG_ARGS=()
KUBECONFIG_PATH=""

# 仅删除本脚本实际创建的 namespace，避免 --namespace 指向已有 namespace 时误删
CREATED_NAMESPACE=false

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
# 计数器 + 失败/复现记录
# ============================================================================
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

# 按测试类目分类的计数器 (用于报告分类汇总)
declare -A CATEGORY_PASS
declare -A CATEGORY_FAIL
declare -A CATEGORY_SKIP
declare -A CATEGORY_TOTAL

# 失败项详情数组: 每条形如 "category|description|reason|repro_cmd"
FAIL_DETAILS=()

# 当前正在运行的测试类目 (由 run_*_tests 设置)
CURRENT_CATEGORY="general"

# 失败类型标记 (用于智能排查建议)
FAIL_TAGS_FILE=""

# verbose 模式
VERBOSE=false

# 选择性运行
ONLY_TESTS=""
SKIP_TESTS=""
SKIP_LB=false

VALID_TESTS=(pod2pod pod2svc multibackend node2pod external dns apiserver samenode mtu hairpin networkpolicy)

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^#//;s/^ //'
}

die() {
    echo "错误: $*" >&2
    exit 2
}

require_arg() {
    local opt="$1"
    local value="${2:-}"
    [[ -n "$value" && "$value" != --* ]] || die "$opt 需要一个参数"
}

validate_positive_int() {
    local value="$1"
    local opt="$2"
    [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || die "$opt 必须是正整数"
}

is_valid_test_name() {
    local name="$1"
    local valid
    for valid in "${VALID_TESTS[@]}"; do
        [[ "$name" == "$valid" ]] && return 0
    done
    return 1
}

validate_test_list() {
    local opt="$1"
    local list="$2"
    local name
    local -a _test_names
    [[ -n "$list" ]] || die "$opt 不能为空"
    IFS=',' read -r -a _test_names <<< "$list"
    for name in "${_test_names[@]}"; do
        [[ -n "$name" ]] || die "$opt 包含空测试名: $list"
        is_valid_test_name "$name" || die "$opt 包含未知测试名: $name (可选: ${VALID_TESTS[*]})"
    done
}

# ============================================================================
# 参数解析
# ============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)       require_arg "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
        --skip-cleanup)    SKIP_CLEANUP=true; shift ;;
        --timeout)         require_arg "$1" "${2:-}"; validate_positive_int "$2" "$1"; TIMEOUT="$2"; shift 2 ;;
        --image)           require_arg "$1" "${2:-}"; IMAGE="$2"; shift 2 ;;
        --spiderpool-subnet)      require_arg "$1" "${2:-}"; SPIDERPOOL_SUBNET="$2"; shift 2 ;;
        --spiderpool-multus)      require_arg "$1" "${2:-}"; SPIDERPOOL_DEFAULT_MULTUS="$2"; SPIDERPOOL_ADDITIONAL_MULTUS="$2"; shift 2 ;;
        --kubeconfig)      require_arg "$1" "${2:-}"; KUBECONFIG_PATH="$2"; KUBECONFIG_ARGS=(--kubeconfig "$2"); shift 2 ;;
        --verbose|-v)      VERBOSE=true; shift ;;
        --skip-lb)         SKIP_LB=true; shift ;;
        --only)            require_arg "$1" "${2:-}"; validate_test_list "$1" "$2"; ONLY_TESTS="$2"; shift 2 ;;
        --skip)            require_arg "$1" "${2:-}"; validate_test_list "$1" "$2"; SKIP_TESTS="$2"; shift 2 ;;
        -h|--help)
            usage
            exit 0 ;;
        # die 用 exit 2: 退出码 1 保留给"有测试失败", 避免 CI 误判
        *) die "未知参数: $1 (用 -h 查看帮助)" ;;
    esac
done

# ============================================================================
# 工具函数
# ============================================================================
kc() {
    kubectl "${KUBECONFIG_ARGS[@]}" "$@"
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
    local cat="${CURRENT_CATEGORY}"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    CATEGORY_TOTAL[$cat]=$(( ${CATEGORY_TOTAL[$cat]:-0} + 1 ))
    case "$status" in
        pass) PASS_COUNT=$((PASS_COUNT + 1))
              CATEGORY_PASS[$cat]=$(( ${CATEGORY_PASS[$cat]:-0} + 1 ))
              log_ok "$desc" ;;
        fail) FAIL_COUNT=$((FAIL_COUNT + 1))
              CATEGORY_FAIL[$cat]=$(( ${CATEGORY_FAIL[$cat]:-0} + 1 ))
              log_fail "$desc" ;;
        skip) SKIP_COUNT=$((SKIP_COUNT + 1))
              CATEGORY_SKIP[$cat]=$(( ${CATEGORY_SKIP[$cat]:-0} + 1 ))
              log_skip "$desc" ;;
    esac
}

# 记录失败详情 (用于报告里集中输出 + 给出复现命令)
# 用法: record_fail_detail "<desc>" "<reason>" "<repro_cmd>" [<tag1> [<tag2>]...]
record_fail_detail() {
    local desc="$1"
    local reason="$2"
    local repro="$3"
    shift 3 || true
    FAIL_DETAILS+=("${CURRENT_CATEGORY}|${desc}|${reason}|${repro}")
    # 记录失败标签 (用于智能排查建议)
    for tag in "$@"; do
        echo "$tag" >> "$FAIL_TAGS_FILE"
    done
    # verbose 模式下立即打印 reason
    if [[ "$VERBOSE" == "true" && -n "$reason" ]]; then
        echo -e "         ${YELLOW}reason:${NC} $reason" | head -3
    fi
}

# 是否应运行某个测试 (供 main 用)
should_run_test() {
    local name="$1"
    if [[ -n "$ONLY_TESTS" ]]; then
        [[ ",${ONLY_TESTS}," == *",${name},"* ]] || return 1
    fi
    if [[ -n "$SKIP_TESTS" ]]; then
        [[ ",${SKIP_TESTS}," == *",${name},"* ]] && return 1
    fi
    return 0
}

# 在 Pod 内执行命令, 带超时, 输出原始 stdout+stderr
exec_in_pod() {
    local pod="$1"; shift
    kc exec -n "$NAMESPACE" "$pod" -- timeout 10 "$@" 2>&1
}

# 在 Pod 内执行命令并捕获输出 (用于失败时诊断)
# 返回值: 命令的 exit code; 输出存到全局 LAST_OUTPUT
#
# 重要: 因为脚本启用了 set -euo pipefail, 命令替换 $( ... ) 中的命令失败
# (例如 timeout / curl / ping 返回非 0) 会触发 set -e 立即终止脚本.
# 用 "|| rc=$?" 模式吞掉非 0 退出, 才能让调用方安全地拿到 exit code.
# 不能写成 "LAST_OUTPUT=$(...)" 然后 "local rc=$?" — 那个 $? 实际是
# local 这个内置命令的退出码, 永远是 0.
LAST_OUTPUT=""
exec_in_pod_capture() {
    local pod="$1"; shift
    local rc=0
    LAST_OUTPUT=$(kc exec -n "$NAMESPACE" "$pod" -- timeout 10 "$@" 2>&1) || rc=$?
    return $rc
}

# 截取输出最后 N 行 (用于报告中失败原因)
last_lines() {
    local n="${1:-3}"
    echo "$LAST_OUTPUT" | tail -n "$n" | sed 's/^[[:space:]]*//' | tr '\n' ';' | sed 's/;$//'
}

shell_join() {
    local out="" arg quoted
    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        out+="${out:+ }${quoted}"
    done
    echo "$out"
}

kubectl_repro_cmd() {
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        shell_join kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"
    else
        shell_join kubectl "$@"
    fi
}

# 拼装一个"可复制粘贴"的 kubectl exec 复现命令
make_repro_cmd() {
    local pod="$1"; shift
    kubectl_repro_cmd exec -n "$NAMESPACE" "$pod" -- "$@"
}

# 等待单个 Pod Ready
# 第 2 个参数可选: 绝对 deadline (SECONDS 基准)。多个 Pod 并发启动, 调用方传同一个
# deadline 让整批共享 TIMEOUT, 避免逐个等待时最坏 N×TIMEOUT。
# deadline 已过也至少检查一次状态 (前面的 Pod 等待期间这个可能早就 Ready 了)。
wait_pod_ready() {
    local pod="$1"
    local deadline="${2:-$((SECONDS + TIMEOUT))}"
    while :; do
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
        [[ $SECONDS -ge $deadline ]] && break
        sleep 2
    done
    log_warn "Pod $pod 未在 ${TIMEOUT}s 内就绪 (当前状态: $(kc get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Unknown'))"
    return 1
}

# 获取 Pod IP (默认网络); kc 失败时返回空而不是非 0 (set -e 下 $() 赋值不能失败)
get_pod_ip() {
    kc get pod -n "$NAMESPACE" "$1" -o jsonpath='{.status.podIP}' 2>/dev/null || true
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

# 获取节点列表 (优先返回 Ready 且未 cordon 的节点，再 fallback 到所有节点)
get_nodes() {
    # NotReady 节点必须排除: pod 用 nodeName 硬 pin (绕过调度器), 落在死节点上会全部起不来
    local candidates
    candidates=$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.unschedulable}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
        | awk -F'\t' '$2 != "true" && $3 == "True" {printf "%s ", $1}' || true)
    if [[ -n "${candidates// /}" ]]; then
        echo "$candidates" | xargs
    else
        kc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true
    fi
}

# 获取节点 InternalIP
get_node_ip() {
    kc get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true
}

get_service_lb_addr() {
    local svc="$1"
    local ip hostname
    ip=$(kc get svc -n "$NAMESPACE" "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi
    hostname=$(kc get svc -n "$NAMESPACE" "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    [[ -n "$hostname" ]] && echo "$hostname"
    # 无 LB 地址时也必须返回 0: 调用方在 set -e 下用 $(...) 赋值, 返回 1 会终止整个脚本
    return 0
}

# 获取 Pod 所在节点
get_pod_node() {
    kc get pod -n "$NAMESPACE" "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true
}

# 校验 Multus NAD 引用。由于测试 namespace 是临时创建的，Spiderpool NAD 必须写成 namespace/name。
validate_nad_ref() {
    local ref="$1"
    local purpose="$2"
    local nad_ns nad_name

    if [[ "$ref" != */* ]]; then
        log_warn "Spiderpool ${purpose} NAD '$ref' 未包含 namespace；临时 namespace 中无法预先找到该 NAD"
        log_warn "请使用 namespace/name 格式，例如 spiderpool/l2-ens4"
        return 1
    fi

    nad_ns="${ref%%/*}"
    nad_name="${ref#*/}"
    if [[ -z "$nad_ns" || -z "$nad_name" || "$nad_name" == */* ]]; then
        log_warn "Spiderpool ${purpose} NAD 引用格式无效: $ref"
        return 1
    fi

    if ! kc get network-attachment-definitions.k8s.cni.cncf.io -n "$nad_ns" "$nad_name" &>/dev/null; then
        log_warn "未找到 Spiderpool ${purpose} NAD: $ref"
        return 1
    fi
    log_info "Spiderpool ${purpose} NAD: $ref"
    return 0
}

# ============================================================================
# 清理函数
# ============================================================================
cleanup() {
    if [[ "$SKIP_CLEANUP" == "true" ]]; then
        log_warn "跳过清理。资源保留在 namespace: $NAMESPACE"
        if [[ "$CREATED_NAMESPACE" == "true" ]]; then
            log_warn "手动清理: $(kubectl_repro_cmd delete namespace "$NAMESPACE")"
        else
            log_warn "Namespace $NAMESPACE 不是本脚本创建的，不会自动删除"
        fi
        return
    fi
    if [[ "$CREATED_NAMESPACE" != "true" ]]; then
        log_info "Namespace $NAMESPACE 不是本脚本创建的，跳过删除"
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

    # python3 用于解析 Multus network-status 注解 (get_pod_multus_ip)
    if ! command -v python3 &>/dev/null; then
        log_warn "python3 未安装 — 无法解析 Multus 附加网络 IP, 相关测试将被 skip"
    fi

    # 集群连接
    if ! kc cluster-info &>/dev/null; then
        echo "错误: 无法连接到 Kubernetes 集群" >&2; exit 1
    fi
    log_info "集群连接正常"

    # 检测节点数 (守护管道: list nodes 失败时走下面的明确报错, 而不是被 set -e 带诊断栈杀掉)
    local node_count
    node_count=$(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
    log_info "集群节点数: $node_count"
    if [[ -z "$node_count" || "$node_count" -eq 0 ]]; then
        echo "错误: 未发现任何节点 (集群没有节点，或当前账号无 list nodes 权限)" >&2; exit 1
    fi
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

    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        local nad_ok=true
        validate_nad_ref "$SPIDERPOOL_DEFAULT_MULTUS" "默认网络" || nad_ok=false
        if [[ "$SPIDERPOOL_ADDITIONAL_MULTUS" != "$SPIDERPOOL_DEFAULT_MULTUS" ]]; then
            validate_nad_ref "$SPIDERPOOL_ADDITIONAL_MULTUS" "附加网络" || nad_ok=false
        fi
        if [[ "$nad_ok" != "true" ]]; then
            SPIDERPOOL_INSTALLED=false
            log_warn "Spiderpool NAD 不可用 — Spiderpool 相关测试将被跳过"
        fi
    fi

    # 检测 LoadBalancer 支持 (MetalLB / Cloud LB)
    LB_SUPPORTED=false
    if [[ "$SKIP_LB" == "true" ]]; then
        log_info "LoadBalancer: 已通过 --skip-lb 跳过"
    elif kc get crd ipaddresspools.metallb.io &>/dev/null 2>&1 || \
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

    if kc get namespace "$NAMESPACE" &>/dev/null; then
        log_fail "Namespace $NAMESPACE 已存在，为避免覆盖或误删已有资源，脚本不会复用已有 namespace"
        log_info "请换一个 --namespace，或先手动删除: $(kubectl_repro_cmd delete namespace "$NAMESPACE")"
        exit 1
    fi
    kc create namespace "$NAMESPACE"
    CREATED_NAMESPACE=true
    # enforce=privileged: node2pod 的 hostNetwork 探测 pod 和 debug node 的 debugger pod
    # 在启用 Pod Security Admission 的集群上需要 privileged 级别
    kc label namespace "$NAMESPACE" purpose=network-test \
        pod-security.kubernetes.io/enforce=privileged --overwrite

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
    multi-backend: "true"
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
EOF

    if should_run_test pod2svc && [[ "$SKIP_LB" != "true" ]]; then
        log_info "创建 LoadBalancer Service..."
        kc apply -n "$NAMESPACE" -f - <<EOF
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
    else
        log_info "跳过创建 LoadBalancer Service (--skip-lb 或未运行 pod2svc 测试)"
    fi

    # ------------------------------------------------------------------
    # 多后端 Service (黑洞检测): http-server-2 放在 node2, 与 http-server
    # 组成跨节点双后端 — 单边路径不通时表现为部分请求超时
    # ------------------------------------------------------------------
    if should_run_test multibackend; then
        log_info "创建多后端 Service (http-server-2 @ ${node2})..."
        kc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: http-server-2
  labels:
    app: http-server-2
    cni-type: default
    multi-backend: "true"
spec:
  nodeName: ${node2}
  containers:
  - name: netshoot
    image: ${IMAGE}
    command:
    - sh
    - -c
    - |
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
  name: svc-clusterip-multi
spec:
  type: ClusterIP
  selector:
    multi-backend: "true"
  ports:
  - port: 80
    targetPort: 8080
    name: http
EOF
    fi

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
    log_info "等待所有测试 Pod 就绪 (整批共享 ${TIMEOUT}s)..."
    local all_pods
    all_pods=$(kc get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    local failed_pods=()
    local wait_deadline=$((SECONDS + TIMEOUT))
    for pod in $all_pods; do
        log_info "  等待 $pod ..."
        if ! wait_pod_ready "$pod" "$wait_deadline"; then
            failed_pods+=("$pod")
        fi
    done

    # 诊断输出全部兜底: 这里跑在"已经出问题"的路径上, pod 中途被删/API 抖动
    # 不能反过来把整个测试进程杀掉
    if [[ ${#failed_pods[@]} -gt 0 ]]; then
        log_warn "以下 Pod 未就绪，相关测试可能失败: ${failed_pods[*]}"
        log_info "Pod 状态详情:"
        kc get pods -n "$NAMESPACE" -o wide || true
        echo ""
        for fp in "${failed_pods[@]}"; do
            log_info "--- $fp events ---"
            kc describe pod -n "$NAMESPACE" "$fp" 2>/dev/null | tail -20 || true
        done
    fi

    log_info "当前 Pod 状态:"
    kc get pods -n "$NAMESPACE" -o wide || true
    echo ""
    log_info "当前 Service 状态:"
    kc get svc -n "$NAMESPACE" -o wide || true
}

# ============================================================================
# 测试函数
# ============================================================================

# ---------- 帮助函数: 给 desc 自动追加 [same-node]/[cross-node] 标注 ----------
# 用法: location_tag <pod-a> <pod-b>  -> 输出 "[same-node]" 或 "[cross-node]"
location_tag() {
    local n1 n2
    n1=$(get_pod_node "$1" 2>/dev/null)
    n2=$(get_pod_node "$2" 2>/dev/null)
    if [[ -z "$n1" || -z "$n2" ]]; then
        echo ""
    elif [[ "$n1" == "$n2" ]]; then
        echo "[same-node]"
    else
        echo "[cross-node]"
    fi
}

# ---------- Pod → Pod (ping) ----------
test_pod_to_pod_ping() {
    local src="$1" dst="$2" desc="$3"
    local dst_ip
    dst_ip=$(get_pod_ip "$dst")
    if [[ -z "$dst_ip" ]]; then
        record_result skip "$desc (无法获取目标 IP)"
        return
    fi
    local loc; loc=$(location_tag "$src" "$dst")
    desc="$desc $loc"
    if exec_in_pod_capture "$src" ping -c 2 -W 3 "$dst_ip"; then
        record_result pass "$desc  [$src → $dst ($dst_ip)]"
    else
        record_result fail "$desc  [$src → $dst ($dst_ip)]"
        local repro; repro=$(make_repro_cmd "$src" ping -c 2 -W 3 "$dst_ip")
        local tags=("pod2pod")
        [[ "$loc" == "[cross-node]" ]] && tags+=("cross-node")
        # 检测是否是 spider→calico 跨节点 (这次踩坑的特征)
        [[ "$src" == pod-spider* && "$dst" == pod-default* && "$loc" == "[cross-node]" ]] && tags+=("spider-to-calico-crossnode")
        [[ "$src" == pod-default* && "$dst" == pod-spider* && "$loc" == "[cross-node]" ]] && tags+=("calico-to-spider-crossnode")
        record_fail_detail "$desc [$src → $dst ($dst_ip)]" "$(last_lines 2)" "$repro" "${tags[@]}"
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
    local loc; loc=$(location_tag "$src" "$dst")
    desc="$desc $loc"
    if exec_in_pod_capture "$src" ping -c 2 -W 3 "$dst_ip"; then
        record_result pass "$desc  [$src → $dst multus-ip ($dst_ip)]"
    else
        record_result fail "$desc  [$src → $dst multus-ip ($dst_ip)]"
        local repro; repro=$(make_repro_cmd "$src" ping -c 2 -W 3 "$dst_ip")
        record_fail_detail "$desc [$src → $dst multus-ip ($dst_ip)]" "$(last_lines 2)" "$repro" "pod2pod" "multus"
    fi
}

# ---------- Pod → Service (curl) ----------
# 第 4 个参数可选: tag (lb/clusterip/nodeport/...) 用于失败标签
test_pod_to_svc() {
    local src="$1" svc_addr="$2" desc="$3" tag="${4:-svc}"
    # nc 伪 HTTP server 单连接 + 循环重启之间有空隙, 失败时重试一次避免偶发 refused 误报
    local rc=0 ok=false attempt
    for attempt in 1 2; do
        rc=0
        exec_in_pod_capture "$src" curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${svc_addr}" || rc=$?
        if [[ $rc -eq 0 ]] && echo "$LAST_OUTPUT" | grep -q "200"; then
            ok=true
            break
        fi
        sleep 1
    done
    if [[ "$ok" == "true" ]]; then
        record_result pass "$desc  [$src → $svc_addr]"
    else
        record_result fail "$desc  [$src → $svc_addr]"
        local repro; repro=$(make_repro_cmd "$src" curl -v --connect-timeout 5 "http://${svc_addr}")
        local reason="HTTP=${LAST_OUTPUT:-N/A}, exit=$rc"
        record_fail_detail "$desc [$src → $svc_addr]" "$reason" "$repro" "pod2svc" "$tag"
    fi
}

# ---------- 多后端 Service 黑洞检测 ----------
# 单次 curl 会漏掉"一半后端不可达"这种间歇性问题: 连发 N 次并核对命中的后端数。
test_svc_multibackend() {
    local src="$1" svc_ip="$2" desc_prefix="$3"
    local n=10
    local desc="${desc_prefix} 多后端 ClusterIP ${n} 连发 (${svc_ip}:80)"

    # 循环放在 pod 内跑 (单次 exec, 避免 N 次 kubectl exec 开销);
    # 失败即重试一次, 吸收 nc 单连接监听循环的重启空隙
    local probe_script="
for i in \$(seq 1 ${n}); do
    out=\$(curl -s --connect-timeout 3 --max-time 5 http://${svc_ip}:80/ 2>/dev/null)
    if [ -z \"\$out\" ]; then sleep 1; out=\$(curl -s --connect-timeout 3 --max-time 5 http://${svc_ip}:80/ 2>/dev/null); fi
    echo \"\$out\" | grep -o 'OK from [^ ]*' || echo __FAIL__
done"
    local raw rc=0
    # 130s: 最坏情况每次迭代 curl 5s + sleep 1 + 重试 5s = 11s × 10 次 = 110s, 留余量
    raw=$(kc exec -n "$NAMESPACE" "$src" -- timeout 130 sh -c "$probe_script" 2>/dev/null) || rc=$?

    local ok distinct
    ok=$(echo "$raw" | grep -c "OK from" || true)
    distinct=$(echo "$raw" | grep "OK from" | sort -u | grep -c . || true)

    local ep_repro; ep_repro=$(kubectl_repro_cmd get endpoints -n "$NAMESPACE" svc-clusterip-multi -o wide)
    if [[ "$ok" -eq "$n" && "$distinct" -ge 2 ]]; then
        record_result pass "$desc: ${ok}/${n} 成功, 命中 ${distinct} 个后端  [$src]"
    elif [[ "$ok" -eq "$n" ]]; then
        record_result fail "$desc: ${ok}/${n} 成功但全部命中同一后端  [$src]"
        record_fail_detail "$desc [$src]" \
            "全部请求命中同一后端, 另一后端可能不在 endpoints 轮转中 (Pod NotReady?)" \
            "$ep_repro" \
            "multibackend"
    elif [[ "$ok" -gt 0 ]]; then
        record_result fail "$desc: 仅 ${ok}/${n} 成功 — 部分请求黑洞  [$src]"
        record_fail_detail "$desc [$src]" \
            "部分请求失败/超时, 典型原因: 某个后端所在节点的转发路径不通" \
            "${ep_repro}; $(make_repro_cmd "$src" curl -sv --connect-timeout 3 "http://${svc_ip}:80/")" \
            "multibackend" "partial-blackhole"
    else
        record_result fail "$desc: 0/${n} 成功  [$src]"
        record_fail_detail "$desc [$src]" \
            "全部请求失败 (exit=$rc), 先看 Pod→SVC 基础测试结果" \
            "${ep_repro}; $(make_repro_cmd "$src" curl -sv --connect-timeout 3 "http://${svc_ip}:80/")" \
            "multibackend"
    fi
}

# ---------- Pod → External (ping + curl) ----------
test_pod_to_external() {
    local src="$1" desc_prefix="$2"

    # ping 外部 IP
    if exec_in_pod_capture "$src" ping -c 2 -W 3 "$TEST_EXTERNAL_IP"; then
        record_result pass "${desc_prefix}: ping 外部 IP ($TEST_EXTERNAL_IP)"
    else
        record_result fail "${desc_prefix}: ping 外部 IP ($TEST_EXTERNAL_IP)"
        record_fail_detail "${desc_prefix} ping 外部 IP ($TEST_EXTERNAL_IP)" \
            "$(last_lines 2)" \
            "$(make_repro_cmd "$src" ping -c 2 -W 3 "$TEST_EXTERNAL_IP")" \
            "external"
    fi

    # DNS 解析 + curl 外部域名
    local rc=0
    exec_in_pod_capture "$src" curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${TEST_EXTERNAL_HOST}" || rc=$?
    if [[ $rc -eq 0 ]] && echo "$LAST_OUTPUT" | grep -qE "200|301|302"; then
        record_result pass "${desc_prefix}: curl 外部域名 ($TEST_EXTERNAL_HOST)"
    else
        record_result fail "${desc_prefix}: curl 外部域名 ($TEST_EXTERNAL_HOST)"
        record_fail_detail "${desc_prefix} curl 外部域名 ($TEST_EXTERNAL_HOST)" \
            "HTTP=${LAST_OUTPUT:-N/A}" \
            "$(make_repro_cmd "$src" curl -v --connect-timeout 5 "http://${TEST_EXTERNAL_HOST}")" \
            "external"
    fi
}

# ---------- Pod → Kubernetes API Server ----------
test_pod_to_apiserver() {
    local src="$1" desc="$2"
    # 使用 ServiceAccount token 访问 /healthz
    local rc=0
    exec_in_pod_capture "$src" sh -c 'curl -sk --connect-timeout 5 -o /dev/null -w "%{http_code}" https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/healthz' || rc=$?
    local code="${LAST_OUTPUT:-000}"
    if [[ $rc -eq 0 && "$code" =~ ^(200|401|403)$ ]]; then
        record_result pass "$desc (HTTP $code, 网络可达)"
    else
        record_result fail "$desc (HTTP $code, exit=$rc)"
        record_fail_detail "$desc" "HTTP=$code, exit=$rc" \
            "$(make_repro_cmd "$src" sh -c 'curl -vk --connect-timeout 5 https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/healthz')" \
            "apiserver"
    fi
}

# ---------- Pod → CoreDNS 解析测试 ----------
test_pod_dns() {
    local src="$1" desc="$2"

    # 集群内 Service DNS (.svc 短后缀: 自定义 cluster domain 也能经 search 域解析)
    if exec_in_pod_capture "$src" nslookup "kubernetes.default.svc"; then
        record_result pass "${desc}: 集群内 DNS (kubernetes.default)"
    else
        record_result fail "${desc}: 集群内 DNS (kubernetes.default)"
        record_fail_detail "${desc}: 集群内 DNS" "$(last_lines 2)" \
            "$(make_repro_cmd "$src" nslookup kubernetes.default.svc)" \
            "dns" "internal-dns"
    fi

    # 短名解析 (走 resolv.conf 的 search 域; ndots/search 配置问题只在这里暴露)
    if exec_in_pod_capture "$src" nslookup "svc-clusterip"; then
        record_result pass "${desc}: 集群内 DNS 短名 (svc-clusterip)"
    else
        record_result fail "${desc}: 集群内 DNS 短名 (svc-clusterip)"
        record_fail_detail "${desc}: 集群内 DNS 短名 (svc-clusterip)" "$(last_lines 2)" \
            "$(make_repro_cmd "$src" nslookup svc-clusterip)" \
            "dns" "internal-dns"
    fi

    # 外部域名 DNS
    if exec_in_pod_capture "$src" nslookup "$TEST_EXTERNAL_HOST"; then
        record_result pass "${desc}: 外部 DNS ($TEST_EXTERNAL_HOST)"
    else
        record_result fail "${desc}: 外部 DNS ($TEST_EXTERNAL_HOST)"
        record_fail_detail "${desc}: 外部 DNS ($TEST_EXTERNAL_HOST)" "$(last_lines 2)" \
            "$(make_repro_cmd "$src" nslookup "$TEST_EXTERNAL_HOST")" \
            "dns" "external-dns"
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
    # 兼容: 如果 debug node 不可用, 使用 hostNetwork Pod 方式
    # --attach=true 必须显式给出: 默认 false 时命令输出不会回传, __PING_OK__ 永远匹配不到
    # -n 指定测试 namespace: debugger pod 随 namespace 清理, 不会泄漏到 default
    local result
    result=$(kc debug "node/${node}" -n "$NAMESPACE" --image="${IMAGE}" -q --attach=true -- \
        sh -c "ping -c 2 -W 3 ${pod_ip} && echo __PING_OK__" 2>&1 </dev/null || true)

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
        record_fail_detail "$desc [node:$node → $pod ($pod_ip)]" \
            "kubectl debug node 与 hostNetwork pod 两种方式均失败" \
            "kubectl debug node/$node --image=$IMAGE -- ping -c 2 $pod_ip" \
            "node2pod"
        kc delete pod -n "$NAMESPACE" "$hostnet_pod" --ignore-not-found &>/dev/null || true
    fi
}

# ============================================================================
# 主测试流程
# ============================================================================

run_pod_to_pod_tests() {
    CURRENT_CATEGORY="pod2pod"
    log_section "测试 1: Pod → Pod 连通性"

    local nodes
    read -r -a nodes <<< "$(get_nodes)"
    local multi_node=false
    [[ ${#nodes[@]} -ge 2 ]] && multi_node=true

    # --- Type A: 默认 CNI ---
    log_info "--- Type A (默认 CNI) ---"
    test_pod_to_pod_ping "pod-default-1" "pod-default-2" "[A→A] 默认CNI Pod 间"

    # --- Type B: Spiderpool 默认网络 ---
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        log_info "--- Type B (Spiderpool 默认网络) ---"
        test_pod_to_pod_ping "pod-spider-1" "pod-spider-2" "[B→B] Spiderpool Pod 间"
    fi

    # --- Type C: 双网络 ---
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        log_info "--- Type C (默认 CNI + Spiderpool 附加) ---"
        test_pod_to_pod_ping "pod-dual-1" "pod-dual-2" "[C→C] 双网络 Pod 间 - 默认网络"
        test_pod_to_pod_multus_ping "pod-dual-1" "pod-dual-2" "[C→C] 双网络 Pod 间 - Multus 附加网络"
    fi

    # --- 跨 CNI 类型互通 ---
    # 改进: 同时覆盖同节点和跨节点。这次踩坑就是因为只测同节点掩盖了
    #      pod-spider→pod-default 跨节点不通的问题。
    log_info "--- 跨 CNI 类型互通 (同节点 + 跨节点) ---"
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        # 同节点用例 (源/目标都是 *-1，调度在 node1)
        test_pod_to_pod_ping "pod-default-1" "pod-spider-1" "[A→B] 默认CNI → Spiderpool"
        test_pod_to_pod_ping "pod-spider-1" "pod-default-1" "[B→A] Spiderpool → 默认CNI"
        test_pod_to_pod_ping "pod-default-1" "pod-dual-1"   "[A→C] 默认CNI → 双网络(默认)"
        test_pod_to_pod_ping "pod-dual-1" "pod-default-1"   "[C→A] 双网络 → 默认CNI"
        test_pod_to_pod_ping "pod-spider-1" "pod-dual-1"    "[B→C] Spiderpool → 双网络(默认)"
        test_pod_to_pod_ping "pod-dual-1" "pod-spider-1"    "[C→B] 双网络 → Spiderpool"

        # 跨节点用例 (仅多节点集群)
        if $multi_node; then
            test_pod_to_pod_ping "pod-default-1" "pod-spider-2" "[A→B] 默认CNI → Spiderpool"
            test_pod_to_pod_ping "pod-spider-1" "pod-default-2" "[B→A] Spiderpool → 默认CNI"
            test_pod_to_pod_ping "pod-default-1" "pod-dual-2"   "[A→C] 默认CNI → 双网络(默认)"
            test_pod_to_pod_ping "pod-dual-1" "pod-default-2"   "[C→A] 双网络 → 默认CNI"
            test_pod_to_pod_ping "pod-spider-1" "pod-dual-2"    "[B→C] Spiderpool → 双网络(默认)"
            test_pod_to_pod_ping "pod-dual-1" "pod-spider-2"    "[C→B] 双网络 → Spiderpool"
        fi
    fi
}

run_pod_to_svc_tests() {
    CURRENT_CATEGORY="pod2svc"
    log_section "测试 2: Pod → Service 连通性"

    local clusterip
    clusterip=$(kc get svc -n "$NAMESPACE" svc-clusterip -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    local nodeport
    nodeport=$(kc get svc -n "$NAMESPACE" svc-nodeport -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
    local lb_ip
    lb_ip=$(get_service_lb_addr svc-lb)
    # LB 控制器分配 VIP 需要时间 (MetalLB 数秒, 云 LB 可能数分钟), 确认有 LB 支持时轮询等待
    if [[ -z "$lb_ip" && "$SKIP_LB" != "true" && "$LB_SUPPORTED" == "true" ]]; then
        log_info "等待 LoadBalancer 分配地址 (最多 60s)..."
        local lb_deadline=$((SECONDS + 60))
        while [[ -z "$lb_ip" && $SECONDS -lt $lb_deadline ]]; do
            sleep 5
            lb_ip=$(get_service_lb_addr svc-lb)
        done
    fi

    local nodes
    read -r -a nodes <<< "$(get_nodes)"
    local node_ip
    node_ip=$(get_node_ip "${nodes[0]}")
    # node2 上没有 http-server 后端: 经 node2 的 NodePort 走 kube-proxy 跨节点转发路径
    local node2_ip=""
    [[ ${#nodes[@]} -ge 2 ]] && node2_ip=$(get_node_ip "${nodes[1]}")

    # 定义要测试的源 Pod 列表
    # 改进: spider/dual 同时覆盖 *-1 和 *-2 两个节点的源
    #       (LB VIP 通常只在某个节点，单源测试可能漏掉同节点 macvlan 限制问题)
    local src_pods=("pod-default-1")
    local src_labels=("TypeA-默认CNI")
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        src_pods+=("pod-spider-1" "pod-dual-1")
        src_labels+=("TypeB-Spiderpool(node1)" "TypeC-双网络(node1)")
        if [[ ${#nodes[@]} -ge 2 ]]; then
            src_pods+=("pod-spider-2" "pod-dual-2")
            src_labels+=("TypeB-Spiderpool(node2)" "TypeC-双网络(node2)")
        fi
    fi

    for idx in "${!src_pods[@]}"; do
        local src="${src_pods[$idx]}"
        local label="${src_labels[$idx]}"

        log_info "--- 源: ${label} (${src}) ---"

        # ClusterIP - by IP
        if [[ -n "$clusterip" ]]; then
            test_pod_to_svc "$src" "${clusterip}:80" \
                "[${label}] → ClusterIP ($clusterip:80)" "clusterip"
        fi

        # ClusterIP - by DNS name (.svc 短后缀, 兼容自定义 cluster domain)
        test_pod_to_svc "$src" "svc-clusterip.${NAMESPACE}.svc:80" \
            "[${label}] → ClusterIP (DNS: svc-clusterip)" "clusterip-dns"

        # NodePort (node1 = http-server 所在节点)
        if [[ -n "$nodeport" && -n "$node_ip" ]]; then
            test_pod_to_svc "$src" "${node_ip}:${nodeport}" \
                "[${label}] → NodePort (${node_ip}:${nodeport})" "nodeport"
        else
            record_result skip "[${label}] → NodePort (无法获取 NodePort)"
        fi

        # NodePort 经无后端节点 (kube-proxy 跨节点转发, VXLAN offload 等问题的典型暴露点)
        if [[ -n "$nodeport" && -n "$node2_ip" ]]; then
            test_pod_to_svc "$src" "${node2_ip}:${nodeport}" \
                "[${label}] → NodePort 无后端节点 (${node2_ip}:${nodeport})" "nodeport-remote"
        fi

        # LoadBalancer
        if [[ "$SKIP_LB" == "true" ]]; then
            record_result skip "[${label}] → LoadBalancer (--skip-lb)"
        elif [[ -n "$lb_ip" ]]; then
            test_pod_to_svc "$src" "${lb_ip}:80" \
                "[${label}] → LoadBalancer ($lb_ip:80)" "lb"
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
                    "[${src_labels[$idx]}] → Spiderpool SVC ClusterIP ($spider_clusterip:80)" "spider-clusterip"
            done
        fi
    fi
}

run_multibackend_tests() {
    CURRENT_CATEGORY="multibackend"
    log_section "测试 2b: 多后端 Service 黑洞检测"

    local svc_ip
    svc_ip=$(kc get svc -n "$NAMESPACE" svc-clusterip-multi -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -z "$svc_ip" ]]; then
        record_result skip "多后端 Service svc-clusterip-multi 不存在"
        return
    fi

    # 就绪后端不足 2 个测不出黑洞, 直接 skip 并提示
    local ep_count
    ep_count=$(kc get endpoints -n "$NAMESPACE" svc-clusterip-multi \
        -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | grep -c . || true)
    if [[ "$ep_count" -lt 2 ]]; then
        record_result skip "多后端黑洞检测: 就绪后端 ${ep_count}/2 (检查 http-server / http-server-2 是否 Ready)"
        return
    fi

    test_svc_multibackend "pod-default-1" "$svc_ip" "[TypeA-默认CNI]"
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_svc_multibackend "pod-spider-1" "$svc_ip" "[TypeB-Spiderpool]"
        test_svc_multibackend "pod-dual-1"   "$svc_ip" "[TypeC-双网络]"
    fi
}

run_node_to_pod_tests() {
    CURRENT_CATEGORY="node2pod"
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
    CURRENT_CATEGORY="external"
    log_section "测试 4: Pod → 外部网络"

    test_pod_to_external "pod-default-1" "[TypeA-默认CNI]"

    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_pod_to_external "pod-spider-1" "[TypeB-Spiderpool]"
        test_pod_to_external "pod-dual-1"   "[TypeC-双网络]"
    fi
}

run_dns_tests() {
    CURRENT_CATEGORY="dns"
    log_section "测试 5: DNS 解析"

    test_pod_dns "pod-default-1" "[TypeA-默认CNI]"

    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_pod_dns "pod-spider-1" "[TypeB-Spiderpool]"
        test_pod_dns "pod-dual-1"   "[TypeC-双网络]"
    fi
}

run_apiserver_tests() {
    CURRENT_CATEGORY="apiserver"
    log_section "测试 6: Pod → Kubernetes API Server"

    test_pod_to_apiserver "pod-default-1" "[TypeA-默认CNI] → API Server"

    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_pod_to_apiserver "pod-spider-1" "[TypeB-Spiderpool] → API Server"
        test_pod_to_apiserver "pod-dual-1"   "[TypeC-双网络] → API Server"
    fi
}

run_same_node_cross_node_tests() {
    CURRENT_CATEGORY="samenode"
    log_section "测试 7: 同节点 vs 跨节点对比 (TCP 连通)"

    local nodes
    read -r -a nodes <<< "$(get_nodes)"
    if [[ ${#nodes[@]} -lt 2 ]]; then
        record_result skip "跨节点测试: 集群节点不足 2 个"
        return
    fi

    local server_ip
    server_ip=$(get_pod_ip "http-server")
    if [[ -z "$server_ip" ]]; then
        record_result skip "无法获取 http-server IP"
        return
    fi

    # 改进: 覆盖 Type A / B / C 三种源
    log_info "--- 同节点 TCP (源都在 node1, http-server 也在 node1) ---"
    test_pod_to_svc "pod-default-1" "${server_ip}:8080" \
        "[同节点] pod-default-1 → http-server (直连 Pod IP)" "samenode-tcp"
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_pod_to_svc "pod-spider-1" "${server_ip}:8080" \
            "[同节点] pod-spider-1 → http-server (直连 Pod IP)" "samenode-tcp"
        test_pod_to_svc "pod-dual-1" "${server_ip}:8080" \
            "[同节点] pod-dual-1 → http-server (直连 Pod IP)" "samenode-tcp"
    fi

    log_info "--- 跨节点 TCP (源在 node2, http-server 在 node1) ---"
    test_pod_to_svc "pod-default-2" "${server_ip}:8080" \
        "[跨节点] pod-default-2 → http-server (直连 Pod IP)" "crossnode-tcp"
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        test_pod_to_svc "pod-spider-2" "${server_ip}:8080" \
            "[跨节点] pod-spider-2 → http-server (直连 Pod IP)" "crossnode-tcp"
        test_pod_to_svc "pod-dual-2" "${server_ip}:8080" \
            "[跨节点] pod-dual-2 → http-server (直连 Pod IP)" "crossnode-tcp"
    fi
}

run_mtu_test() {
    CURRENT_CATEGORY="mtu"
    log_section "测试 8: MTU / 大包测试"

    # 关键改进: 先用小包 (-s 56) 测连通性
    #   - 小包通+大包不通 = 真 MTU 问题
    #   - 小包就不通      = 连通性问题, MTU 测试会被误诊断
    # 这次踩坑就是因为没做这一步，把"完全不通"误报为"MTU 过小"。

    local nodes
    read -r -a nodes <<< "$(get_nodes)"
    local multi_node=false
    [[ ${#nodes[@]} -ge 2 ]] && multi_node=true

    # 测试矩阵: src × dst
    #   - 同节点 default 目标 (基线)
    #   - 跨节点 default 目标 (跨节点 overlay 路径，最常见的 MTU 限制场景)
    #   - 跨节点 spider 目标 (underlay 路径，与 overlay 不同)
    declare -a srcs srcs_labels
    srcs=("pod-default-1");      srcs_labels=("TypeA-默认CNI")
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        srcs+=("pod-spider-1" "pod-dual-1")
        srcs_labels+=("TypeB-Spiderpool" "TypeC-双网络")
    fi

    declare -a dsts dsts_labels
    # 默认网络目标 - 跨节点 (主要场景)
    if $multi_node; then
        dsts+=("pod-default-2");   dsts_labels+=("→ default-2 (cross-node)")
    else
        dsts+=("pod-default-2");   dsts_labels+=("→ default-2 (same-node)")
    fi
    # Spiderpool 目标 - 跨节点 (验证 underlay MTU)
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]] && $multi_node; then
        dsts+=("pod-spider-2");    dsts_labels+=("→ spider-2 (cross-node)")
    fi

    for sidx in "${!srcs[@]}"; do
        local src="${srcs[$sidx]}" slabel="${srcs_labels[$sidx]}"
        for didx in "${!dsts[@]}"; do
            local dst="${dsts[$didx]}" dlabel="${dsts_labels[$didx]}"
            local dst_ip; dst_ip=$(get_pod_ip "$dst")
            if [[ -z "$dst_ip" ]]; then
                record_result skip "[${slabel}] MTU ${dlabel}: 无法获取目标 IP"
                continue
            fi

            local prefix="[${slabel}] MTU ${dlabel}"

            # ---------- 步骤 1: 小包连通性 ----------
            if ! exec_in_pod_capture "$src" ping -c 2 -W 3 "$dst_ip"; then
                # 小包就不通，标记为连通性失败 (不是 MTU 问题)
                record_result fail "${prefix}: 小包连通性失败 (非 MTU 问题，请先排查连通性)"
                local repro; repro=$(make_repro_cmd "$src" ping -c 2 "$dst_ip")
                local tags=("mtu" "connectivity-failure")
                # 这次踩坑特征
                [[ "$src" == pod-spider* && "$dst" == pod-default* ]] && tags+=("spider-to-calico-crossnode")
                [[ "$src" == pod-default* && "$dst" == pod-spider* ]] && tags+=("calico-to-spider-crossnode")
                record_fail_detail "${prefix}: 小包连通性失败" "$(last_lines 2)" "$repro" "${tags[@]}"
                continue
            fi

            # ---------- 步骤 2: 按源出接口 MTU 做 DF ping ----------
            # 固定 1400 会误伤合法小 MTU 集群 (WireGuard/双层封装常见 1340-1400)。
            # 真 MTU 问题的准确定义是: 接口宣称的 MTU, 路径承载不了。
            # 所以先查去往目标的出接口 (Type C 到 spider 目标走 net1 而非 eth0),
            # 按其 MTU 计算 payload; 读不到时退回固定 1400。
            local src_dev src_mtu
            src_dev=$(exec_in_pod "$src" sh -c "ip -o route get ${dst_ip} 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p'" 2>/dev/null | tr -d '[:space:]' || true)
            src_mtu=""
            if [[ -n "$src_dev" ]]; then
                src_mtu=$(exec_in_pod "$src" cat "/sys/class/net/${src_dev}/mtu" 2>/dev/null | tr -cd '0-9' || true)
            fi
            if [[ -n "$src_mtu" && "$src_mtu" -gt 128 ]]; then
                local payload=$((src_mtu - 28))
                if exec_in_pod_capture "$src" ping -c 2 -W 5 -M do -s "$payload" "$dst_ip"; then
                    record_result pass "${prefix}: 接口 MTU ${src_mtu} (dev ${src_dev}) DF ping 成功"
                else
                    record_result fail "${prefix}: 接口宣称 MTU ${src_mtu} (dev ${src_dev}) 但路径承载不了 (真 MTU 问题)"
                    record_fail_detail "${prefix}: MTU ${src_mtu} DF ping 失败" "$(last_lines 2)" \
                        "$(make_repro_cmd "$src" ping -M do -s "$payload" "$dst_ip")" \
                        "mtu" "real-mtu-issue"
                fi
            else
                if exec_in_pod_capture "$src" ping -c 2 -W 5 -M do -s 1400 "$dst_ip"; then
                    record_result pass "${prefix}: 1400 字节 DF ping 成功 (未能读取接口 MTU, 用固定值)"
                else
                    record_result fail "${prefix}: 1400 字节 DF ping 失败 (真 MTU 问题: 小包通,大包不通)"
                    record_fail_detail "${prefix}: 1400 DF ping 失败" "$(last_lines 2)" \
                        "$(make_repro_cmd "$src" ping -M do -s 1400 "$dst_ip")" \
                        "mtu" "real-mtu-issue"
                fi
            fi

            # ---------- 步骤 3: 探测实际 MTU ----------
            local mtu_val=""
            for size in 1472 1450 1400 1350 1300 1200 1000; do
                if exec_in_pod "$src" ping -c 1 -W 3 -M do -s "$size" "$dst_ip" &>/dev/null; then
                    mtu_val=$((size + 28))  # ICMP=8 + IP=20
                    break
                fi
            done
            if [[ -n "$mtu_val" ]]; then
                log_info "  ${prefix}: 探测 MTU ≥ ${mtu_val} bytes"
            else
                log_warn "  ${prefix}: 探测 MTU 失败 (理论上不应到这里，因为小包是通的)"
            fi
        done
    done
}

run_hairpin_test() {
    CURRENT_CATEGORY="hairpin"
    log_section "测试 9: Hairpin / 自身访问测试"

    # Pod 通过 Service 访问自身 (hairpin NAT)
    log_info "--- Pod 通过 ClusterIP Service 访问自身 ---"
    # 用 .svc 短后缀而非 .svc.cluster.local: 自定义 cluster domain 的集群
    # 会经 resolv.conf search 第三项 (<domain>) 正确解析, 不产生假失败
    test_pod_to_svc "http-server" "svc-clusterip.${NAMESPACE}.svc:80" \
        "[Hairpin] http-server → 自身 ClusterIP Service" "hairpin"
}

run_network_policy_test() {
    CURRENT_CATEGORY="networkpolicy"
    log_section "测试 10: NetworkPolicy 验证 (可选)"

    # ---------- Type A (默认 CNI) NetworkPolicy ----------
    _np_test_target_tcp "http-server" "app" "http-server" "pod-default-1" "TypeA-默认CNI" 8080

    # ---------- Type A (默认 CNI) Egress NetworkPolicy ----------
    _np_test_egress_tcp "pod-default-1" "instance" "pod-default-1" "http-server" "TypeA-默认CNI" 8080

    # ---------- Type B (Spiderpool macvlan) NetworkPolicy ----------
    # 改进: macvlan 直连模式 NetworkPolicy 通常不生效, 这是已知行为
    #       这里用 WARN 模式验证, 不算 FAIL.
    if [[ "$SPIDERPOOL_INSTALLED" == "true" ]]; then
        _np_test_target_tcp_warn "http-server-spider" "app" "http-server-spider" "pod-spider-1" "TypeB-Spiderpool" 8080
    fi
}

# 辅助: Egress 方向 deny-all (policy 选中源 pod, 验证出方向被阻断 + 删除后恢复)
_np_test_egress_tcp() {
    local src="$1" selector_key="$2" selector_value="$3" target="$4" label="$5" port="${6:-8080}"

    log_info "--- ${label}: Egress NetworkPolicy on ${src} → ${target} TCP/${port} ---"
    local dst_ip; dst_ip=$(get_pod_ip "$target")
    if [[ -z "$dst_ip" ]]; then
        record_result skip "[${label}] Egress NetworkPolicy: 无法获取目标 IP"
        return
    fi

    # 基线走目标 IP 直连: egress deny 也会挡 DNS, 用 IP 排除 DNS 干扰
    if ! exec_in_pod "$src" curl -fsS --connect-timeout 5 "http://${dst_ip}:${port}" &>/dev/null; then
        record_result skip "[${label}] Egress NetworkPolicy: 基线 TCP 连接不通，无法验证策略"
        return
    fi

    kc apply -n "$NAMESPACE" -f - <<EOF >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-egress-${src}
spec:
  podSelector:
    matchLabels:
      ${selector_key}: ${selector_value}
  policyTypes:
  - Egress
  egress: []
EOF

    # 轮询等待策略下发; 连续 2 次失败才判定生效 (理由同 Ingress 测试)
    local enforced=false consec_fail=0
    local np_deadline=$((SECONDS + 20))
    while [[ $SECONDS -lt $np_deadline ]]; do
        if ! exec_in_pod "$src" curl -fsS --connect-timeout 3 "http://${dst_ip}:${port}" &>/dev/null; then
            consec_fail=$((consec_fail + 1))
            if [[ $consec_fail -ge 2 ]]; then
                enforced=true
                break
            fi
        else
            consec_fail=0
        fi
        sleep 2
    done

    if [[ "$enforced" == "true" ]]; then
        record_result pass "[${label}] Egress deny-all 生效: 出方向 TCP 被拒绝"
    else
        record_result fail "[${label}] Egress deny-all 未生效: TCP 仍成功 (CNI 可能不支持 Egress 策略)"
        record_fail_detail "[${label}] Egress NetworkPolicy 未生效" \
            "出方向 TCP 应被拒绝但成功了" \
            "$(kubectl_repro_cmd get networkpolicy -n "$NAMESPACE"); $(make_repro_cmd "$src" curl -v --connect-timeout 5 "http://${dst_ip}:${port}")" \
            "networkpolicy"
    fi

    kc delete networkpolicy -n "$NAMESPACE" "deny-egress-${src}" --ignore-not-found &>/dev/null

    # 轮询等待策略撤销生效
    local recovered=false
    np_deadline=$((SECONDS + 15))
    while [[ $SECONDS -lt $np_deadline ]]; do
        if exec_in_pod "$src" curl -fsS --connect-timeout 3 "http://${dst_ip}:${port}" &>/dev/null; then
            recovered=true
            break
        fi
        sleep 2
    done
    if [[ "$recovered" == "true" ]]; then
        record_result pass "[${label}] Egress 策略删除后恢复: TCP 成功"
    else
        record_result fail "[${label}] Egress 策略删除后未恢复: TCP 仍失败"
        record_fail_detail "[${label}] Egress 策略删除后未恢复" \
            "策略已删除但出方向 TCP 仍不通" \
            "$(make_repro_cmd "$src" curl -v --connect-timeout 5 "http://${dst_ip}:${port}")" \
            "networkpolicy"
    fi
}

# 辅助: 严格模式测试 NetworkPolicy (CNI 必须支持，否则 FAIL)
# 使用 TCP curl 而不是 ICMP ping；ICMP 在 Kubernetes NetworkPolicy 中不是可移植语义。
_np_test_target_tcp() {
    local target="$1" selector_key="$2" selector_value="$3" src="$4" label="$5" port="${6:-8080}"

    log_info "--- ${label}: NetworkPolicy on ${target} TCP/${port} ---"
    local dst_ip; dst_ip=$(get_pod_ip "$target")
    if [[ -z "$dst_ip" ]]; then
        record_result skip "[${label}] NetworkPolicy: 无法获取目标 IP"
        return
    fi

    if ! exec_in_pod "$src" curl -fsS --connect-timeout 5 "http://${dst_ip}:${port}" &>/dev/null; then
        record_result skip "[${label}] NetworkPolicy: 基线 TCP 连接不通，无法验证策略"
        return
    fi

    kc apply -n "$NAMESPACE" -f - <<EOF >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-${target}
spec:
  podSelector:
    matchLabels:
      ${selector_key}: ${selector_value}
  policyTypes:
  - Ingress
  ingress: []
EOF

    # 轮询等待策略下发 (慢 CNI 上固定 sleep 3 会误报"未生效")。
    # 必须连续 2 次失败才判定生效: 单次失败可能只是 nc 重启空隙 / exec 抖动,
    # 会把不支持 NetworkPolicy 的 CNI 误判成 PASS (安全断言假阳性)。
    local enforced=false consec_fail=0
    local np_deadline=$((SECONDS + 20))
    while [[ $SECONDS -lt $np_deadline ]]; do
        if ! exec_in_pod "$src" curl -fsS --connect-timeout 3 "http://${dst_ip}:${port}" &>/dev/null; then
            consec_fail=$((consec_fail + 1))
            if [[ $consec_fail -ge 2 ]]; then
                enforced=true
                break
            fi
        else
            consec_fail=0
        fi
        sleep 2
    done

    if [[ "$enforced" == "true" ]]; then
        record_result pass "[${label}] NetworkPolicy deny-all 生效: TCP 被拒绝"
    else
        record_result fail "[${label}] NetworkPolicy deny-all 未生效: TCP 仍成功 (CNI 可能不支持)"
        record_fail_detail "[${label}] NetworkPolicy 未生效" \
            "TCP 应被拒绝但成功了" \
            "$(kubectl_repro_cmd get networkpolicy -n "$NAMESPACE"); $(make_repro_cmd "$src" curl -v --connect-timeout 5 "http://${dst_ip}:${port}")" \
            "networkpolicy"
    fi

    kc delete networkpolicy -n "$NAMESPACE" "deny-all-${target}" --ignore-not-found &>/dev/null

    # 同样轮询等待策略撤销生效
    local recovered=false
    np_deadline=$((SECONDS + 15))
    while [[ $SECONDS -lt $np_deadline ]]; do
        if exec_in_pod "$src" curl -fsS --connect-timeout 3 "http://${dst_ip}:${port}" &>/dev/null; then
            recovered=true
            break
        fi
        sleep 2
    done

    if [[ "$recovered" == "true" ]]; then
        record_result pass "[${label}] NetworkPolicy 删除后恢复: TCP 成功"
    else
        record_result fail "[${label}] NetworkPolicy 删除后未恢复: TCP 仍失败"
        record_fail_detail "[${label}] NetworkPolicy 删除后未恢复" \
            "策略已删除但 TCP 仍不通" \
            "$(make_repro_cmd "$src" curl -v --connect-timeout 5 "http://${dst_ip}:${port}")" \
            "networkpolicy"
    fi
}

# 辅助: 宽松模式 (用于 Spiderpool macvlan, 不生效是预期行为)
_np_test_target_tcp_warn() {
    local target="$1" selector_key="$2" selector_value="$3" src="$4" label="$5" port="${6:-8080}"

    log_info "--- ${label}: NetworkPolicy on ${target} TCP/${port} (Spiderpool 通常不生效, WARN 模式) ---"
    local dst_ip; dst_ip=$(get_pod_ip "$target")
    if [[ -z "$dst_ip" ]]; then
        record_result skip "[${label}] NetworkPolicy: 无法获取目标 IP"
        return
    fi

    if ! exec_in_pod "$src" curl -fsS --connect-timeout 5 "http://${dst_ip}:${port}" &>/dev/null; then
        record_result skip "[${label}] NetworkPolicy: 基线 TCP 连接不通，无法验证策略"
        return
    fi

    kc apply -n "$NAMESPACE" -f - <<EOF >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-${target}
spec:
  podSelector:
    matchLabels:
      ${selector_key}: ${selector_value}
  policyTypes:
  - Ingress
  ingress: []
EOF
    sleep 3

    # 连续 2 次失败才算生效 (单次失败可能是 nc 空隙误报);
    # macvlan 预期不生效, 首次探测成功即快速走 skip 分支, 不浪费时间
    local blocked=false
    if ! exec_in_pod "$src" curl -fsS --connect-timeout 5 "http://${dst_ip}:${port}" &>/dev/null; then
        sleep 2
        if ! exec_in_pod "$src" curl -fsS --connect-timeout 5 "http://${dst_ip}:${port}" &>/dev/null; then
            blocked=true
        fi
    fi
    if [[ "$blocked" == "true" ]]; then
        record_result pass "[${label}] NetworkPolicy 对 macvlan 生效: TCP 被拒绝 (CNI 支持)"
    else
        # macvlan 模式下 NetworkPolicy 通常不生效, 不算 FAIL
        record_result skip "[${label}] NetworkPolicy 对 macvlan 不生效: TCP 仍成功 (已知限制, 非问题)"
        log_warn "  Spiderpool macvlan 模式下 NetworkPolicy 通常不生效 (流量绕过 host 协议栈)"
    fi

    kc delete networkpolicy -n "$NAMESPACE" "deny-all-${target}" --ignore-not-found &>/dev/null
    sleep 2
}

# ============================================================================
# 打印报告 (分类汇总 + 失败详情 + 智能建议)
# ============================================================================
REPORT_PRINTED=false
print_report() {
    REPORT_PRINTED=true
    log_section "测试报告"
    echo ""
    echo -e "  ${GREEN}通过${NC}: ${PASS_COUNT} / ${TOTAL_COUNT}"
    echo -e "  ${RED}失败${NC}: ${FAIL_COUNT}"
    echo -e "  ${CYAN}跳过${NC}: ${SKIP_COUNT}"
    echo ""

    # ---------- 按测试类目分类汇总 ----------
    echo -e "${BOLD}按类目:${NC}"
    local categories=(pod2pod pod2svc multibackend node2pod external dns apiserver samenode mtu hairpin networkpolicy)
    local labels=(
        "Pod→Pod"  "Pod→SVC"  "Multi-Backend" "Node→Pod" "External"  "DNS"
        "APIServer" "Same/Cross" "MTU"  "Hairpin" "NetworkPolicy"
    )
    for i in "${!categories[@]}"; do
        local c="${categories[$i]}" l="${labels[$i]}"
        local p="${CATEGORY_PASS[$c]:-0}"
        local f="${CATEGORY_FAIL[$c]:-0}"
        local s="${CATEGORY_SKIP[$c]:-0}"
        local t="${CATEGORY_TOTAL[$c]:-0}"
        [[ "$t" == "0" ]] && continue
        local marker="${GREEN}✓${NC}"
        [[ "$f" -gt 0 ]] && marker="${RED}✗${NC}"
        printf "  %s  %-15s  %s/%s  pass" "$(printf "%b" "$marker")" "$l" "$p" "$t"
        [[ "$f" -gt 0 ]] && printf "  ${RED}%s fail${NC}" "$f"
        [[ "$s" -gt 0 ]] && printf "  ${CYAN}%s skip${NC}" "$s"
        printf "\n"
    done
    echo ""

    # ---------- 失败项详情 ----------
    if [[ ${#FAIL_DETAILS[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}失败项详情:${NC}"
        echo ""
        local i=1
        for entry in "${FAIL_DETAILS[@]}"; do
            local cat="${entry%%|*}"; entry="${entry#*|}"
            local desc="${entry%%|*}"; entry="${entry#*|}"
            local reason="${entry%%|*}"; entry="${entry#*|}"
            local repro="${entry}"
            printf "  ${BOLD}%d.${NC} [${RED}%s${NC}] %s\n" "$i" "$cat" "$desc"
            [[ -n "$reason" ]] && printf "       ${YELLOW}reason:${NC} %s\n" "$reason"
            [[ -n "$repro"  ]] && printf "       ${BLUE}repro:${NC}  %s\n" "$repro"
            echo ""
            i=$((i+1))
        done
    fi

    # ---------- 智能排查建议 ----------
    if [[ $FAIL_COUNT -gt 0 ]]; then
        _print_smart_suggestions
    else
        echo -e "${GREEN}${BOLD}✅ 所有测试通过!${NC}"
    fi
    echo ""
}

# 根据失败标签输出有针对性的排查建议
_print_smart_suggestions() {
    echo -e "${YELLOW}${BOLD}排查建议:${NC}"
    echo ""

    # 通用建议
    echo "  通用排查:"
    echo "    kubectl get pods -n $NAMESPACE -o wide"
    echo "    kubectl describe pod <pod> -n $NAMESPACE"
    echo ""

    local tags=""
    [[ -s "$FAIL_TAGS_FILE" ]] && tags=$(sort -u "$FAIL_TAGS_FILE")

    # 这次踩坑场景: spider→calico 跨节点不通
    if echo "$tags" | grep -q "spider-to-calico-crossnode"; then
        echo -e "  ${BOLD}⚠ 检测到 Spiderpool → Calico 跨节点失败${NC}"
        echo "    可能原因: macvlan + Calico 不对称路径 (这次踩坑的典型问题)"
        echo "    解决方案: 在每个节点添加 SNAT 规则:"
        echo "      iptables -t nat -I POSTROUTING 1 \\"
        echo "        -s <SPIDER_CIDR> -d <CALICO_CIDR> -j MASQUERADE \\"
        echo "        -m comment --comment 'spiderpool-to-calico-snat'"
        echo "    详见: TROUBLESHOOTING.md 问题 2"
        echo ""
    fi

    # LB 测试失败
    if echo "$tags" | grep -q "^lb$"; then
        echo -e "  ${BOLD}⚠ 检测到 LoadBalancer 访问失败${NC}"
        echo "    可能原因 1: MetalLB 未给 svc-lb 分配 IP"
        echo "      kubectl get svc -n $NAMESPACE svc-lb"
        echo "    可能原因 2: macvlan pod 访问本节点 LB VIP (macvlan 父子接口限制)"
        echo "      把 LB VIP 加入 SpiderCoordinator hijackCIDR:"
        echo "        kubectl edit spidercoordinator default"
        echo "    详见: TROUBLESHOOTING.md 问题 1"
        echo ""
    fi

    # 真 MTU 问题
    if echo "$tags" | grep -q "real-mtu-issue"; then
        echo -e "  ${BOLD}⚠ 检测到真正的 MTU 问题 (小包通,大包不通)${NC}"
        echo "    可能原因: pod MTU 配置 > 实际链路 MTU (常见于 VXLAN/IPIP 隧道)"
        echo "    检查方法:"
        echo "      ip link show | grep mtu              # 各接口 MTU"
        echo "      kubectl get felixconfiguration -o yaml | grep -i mtu"
        echo ""
    fi

    # MTU 测试中的连通性失败 (而非真 MTU 问题)
    if echo "$tags" | grep -q "connectivity-failure"; then
        echo -e "  ${BOLD}ℹ MTU 测试中检测到连通性失败 (不是 MTU 问题)${NC}"
        echo "    脚本已自动区分: 小包不通时不会误诊为 MTU"
        echo "    请优先排查 Pod→Pod 测试的失败项"
        echo ""
    fi

    # 多后端部分黑洞
    if echo "$tags" | grep -q "partial-blackhole"; then
        echo -e "  ${BOLD}⚠ 检测到多后端 Service 部分请求黑洞${NC}"
        echo "    某个后端方向的转发路径不通 (kube-proxy 仍会把连接分给它 → 间歇性超时)"
        echo "    kubectl get endpoints -n $NAMESPACE svc-clusterip-multi -o wide"
        echo "    先看 Pod→Pod 跨节点测试是否失败; 也常见于 VXLAN checksum offload 问题"
        echo ""
    fi

    # NetworkPolicy 不生效
    if echo "$tags" | grep -q "networkpolicy"; then
        echo -e "  ${BOLD}⚠ 检测到 NetworkPolicy 异常${NC}"
        echo "    检查 CNI 是否支持 NetworkPolicy (Calico/Cilium 支持，flannel 不支持)"
        echo "    检查 Felix 配置: kubectl get felixconfiguration default -o yaml"
        echo ""
    fi

    # DNS 失败
    if echo "$tags" | grep -q "internal-dns\|external-dns\|^dns$"; then
        echo -e "  ${BOLD}⚠ DNS 解析失败${NC}"
        echo "    kubectl get pods -n kube-system | grep -iE 'dns|coredns'"
        echo "    kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50"
        echo ""
    fi

    # 通用收尾
    echo "  完整排查文档: TROUBLESHOOTING.md (含真实案例、抓包技巧、修复脚本)"
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

    if [[ "$VERBOSE" == "true" ]]; then
        log_info "verbose 模式已启用"
    fi
    if [[ -n "$ONLY_TESTS" ]]; then
        log_info "仅运行: $ONLY_TESTS"
    fi
    if [[ -n "$SKIP_TESTS" ]]; then
        log_info "跳过: $SKIP_TESTS"
    fi
    if [[ "$SKIP_LB" == "true" ]]; then
        log_info "LoadBalancer 测试/资源已通过 --skip-lb 跳过"
    fi

    FAIL_TAGS_FILE="$(mktemp -t nettest_tags.XXXXXX)"
    : > "$FAIL_TAGS_FILE"

    # 退出时打印报告 + 清理 tmp 文件 + namespace
    trap '_cleanup_all' EXIT
    # 异常退出时输出诊断信息 (有助于定位 set -e 触发位置)
    trap 'on_unexpected_error $LINENO "$BASH_COMMAND"' ERR

    preflight_check
    create_resources

    # 注: 测试名跟 --only/--skip 的 token 一一对应
    should_run_test pod2pod         && run_pod_to_pod_tests
    should_run_test pod2svc         && run_pod_to_svc_tests
    should_run_test multibackend    && run_multibackend_tests
    should_run_test node2pod        && run_node_to_pod_tests
    should_run_test external        && run_external_tests
    should_run_test dns             && run_dns_tests
    should_run_test apiserver       && run_apiserver_tests
    should_run_test samenode        && run_same_node_cross_node_tests
    should_run_test mtu             && run_mtu_test
    should_run_test hairpin         && run_hairpin_test
    should_run_test networkpolicy   && run_network_policy_test

    print_report

    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
}

# 是否处于退出/清理阶段 (用来抑制清理流程里 [[ ]] 等返回 1 的命令触发 ERR)
IN_CLEANUP=false

# 异常退出时的诊断信息 (供 ERR trap 使用)
on_unexpected_error() {
    local exit_code=$?
    local line_no=${1:-?}
    local cmd="${2:-?}"
    # 清理阶段不输出 (清理过程的 [[ ]] / kubectl delete 等可能正常返回非 0)
    if [[ "$IN_CLEANUP" == "true" ]]; then
        return 0
    fi
    echo "" >&2
    echo -e "${RED}${BOLD}━━━ 脚本意外退出 ━━━${NC}" >&2
    echo -e "${RED}exit_code=${exit_code}  line=${line_no}${NC}" >&2
    echo -e "${RED}command: ${cmd}${NC}" >&2
    echo "" >&2
    echo -e "${YELLOW}这通常意味着某条 kubectl 命令或 pod 内命令异常退出.${NC}" >&2
    echo -e "${YELLOW}已运行的测试结果会在下方报告中给出 (可能不完整).${NC}" >&2
    echo "" >&2
}

# 退出时执行: 打印报告 (即使中途异常) → 清理 namespace → 删 tmp 文件
_cleanup_all() {
    local rc=$?
    # 标记进入清理阶段, 抑制 ERR trap; 同时关闭 set -e
    IN_CLEANUP=true
    set +e
    # 先打印报告 (无论 rc 如何, 让用户看到已跑了哪些测试)
    if [[ "${REPORT_PRINTED:-false}" != "true" && ${TOTAL_COUNT:-0} -gt 0 ]]; then
        print_report
    fi
    rm -f "$FAIL_TAGS_FILE" 2>/dev/null || true
    cleanup
    return $rc
}

main "$@"
