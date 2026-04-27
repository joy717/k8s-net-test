使用方式
# 最简 (自动检测环境, 用完自动清理)
./k8s-net-test.sh
# 指定 spiderpool multus 配置
./k8s-net-test.sh --spiderpool-multus "spiderpool/l2-ens12"
# 保留资源不清理 (便于排查)
./k8s-net-test.sh --skip-cleanup
# 指定 kubeconfig
./k8s-net-test.sh --kubeconfig ~/.kube/my-cluster
自适应特性：脚本会自动检测 Multus/Spiderpool/MetalLB 是否安装，未安装时相关测试自动跳过而非报错。单节点集群时跨节点测试也会自动跳过。

## 排查记录
遇到测试失败可参考 [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)，里面记录了在 Spiderpool macvlan + Calico VXLAN + MetalLB 环境下两个真实问题的完整排查过程、根因和修复方案：
- pod-spider 访问本节点 LoadBalancer 不通（macvlan 父子接口限制 + hijackCIDR 缺失）
- pod-spider 跨节点访问 Calico pod 不通（不对称路径 + macvlan 父接口收包不转给子设备）

