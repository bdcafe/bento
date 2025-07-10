#!/bin/bash
set -e

: <<'LOGIC_DIAGRAM'

逻辑图（Linux Bridge + VLAN untagged 示例）:

       +----------------------+                    +----------------------+
       |  Network Namespace   |                    |  Network Namespace   |
       |         nsA          |                    |         nsB          |
       |  +--------------+    |                    |   +--------------+   |
       |  |  veth1 (IP)  |<===+===veth pair===+===>|   |  veth2 (IP)  |   |
       |  +--------------+    |                    |   +--------------+   |
       +----------------------+                    +----------------------+
                 |                                             |
                 |                                             |
              veth1-br                                      veth2-br
           (untagged VLAN 10)                           (untagged VLAN 20)
                 |                                             |
                 +----------------------+----------------------+
                                        |
                              Linux Bridge br0 (vlan_filtering=1)
                                        |
                 VLAN 10 and VLAN 20 are isolated — no communication
                                        |
                          (ping between nsA and nsB will fail)

说明：
- veth1 <-> veth1-br 是一对虚拟以太网设备
- veth2 <-> veth2-br 同理
- veth1-br 和 veth2-br 都是 br0 的端口，且启用了 VLAN 过滤
- veth1-br 的 VLAN 10 设置为 untagged，veth2-br 的 VLAN 20 设置为 untagged
- 两个 VLAN 互不通信，体现二层交换机的 VLAN 隔离功能

LOGIC_DIAGRAM


# 分隔输出函数
print_section() {
    local msg="$1"
    local width=60
    local edge_line=$(printf '=%.0s' $(seq 1 $width))

    # 计算中英文混合宽度时的视觉长度（1个中文占 2 列）
    local msg_display_width=$(echo -n "$msg" | awk '{
    len = 0
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c ~ /[一-龥]/) len += 2  # 中文宽度为 2
      else len += 1               # 英文宽度为 1
    }
    print len
  }')

    local padding=$(( (width - msg_display_width) / 2 ))
    local pad=$(printf ' %.0s' $(seq 1 $padding))

    echo "$edge_line"
    echo "${pad}${msg}"
    echo "$edge_line"
}

BRIDGE="br0"
NS1="nsA"
NS2="nsB"
VETH1="veth1"
VETH1_BR="veth1-br"
VETH2="veth2"
VETH2_BR="veth2-br"

VLAN1=10
VLAN2=20

cleanup() {
    ip netns del $NS1 2>/dev/null || true
    ip netns del $NS2 2>/dev/null || true
    ip link set $VETH1_BR down 2>/dev/null || true
    ip link set $VETH2_BR down 2>/dev/null || true
    ip link set $BRIDGE down 2>/dev/null || true
    ip link del $BRIDGE 2>/dev/null || true
}
trap cleanup EXIT INT
cleanup

print_section "创建 Linux Bridge 并启用 VLAN filtering"
ip link add name $BRIDGE type bridge vlan_filtering 1
ip link set dev $BRIDGE up
echo "Bridge $BRIDGE 状态："
ip link show $BRIDGE

print_section "创建命名空间 $NS1 和 $NS2"
ip netns add $NS1
ip netns add $NS2
echo "当前命名空间列表："
ip netns list

print_section "创建 veth pair $VETH1 <-> $VETH1_BR"
ip link add $VETH1 type veth peer name $VETH1_BR
ip link set $VETH1 netns $NS1
ip link set $VETH1_BR master $BRIDGE
ip link set $VETH1_BR up
echo "主机端口 $VETH1_BR 状态："
ip link show $VETH1_BR

print_section "创建 veth pair $VETH2 <-> $VETH2_BR"
ip link add $VETH2 type veth peer name $VETH2_BR
ip link set $VETH2 netns $NS2
ip link set $VETH2_BR master $BRIDGE
ip link set $VETH2_BR up
echo "主机端口 $VETH2_BR 状态："
ip link show $VETH2_BR

print_section "配置 VLAN（PVID 设为 untagged）"
bridge vlan add vid $VLAN1 dev $VETH1_BR pvid untagged
bridge vlan add vid $VLAN2 dev $VETH2_BR pvid untagged
echo "当前 VLAN 配置："
bridge vlan show

print_section "启用命名空间接口"
ip netns exec $NS1 ip link set lo up
ip netns exec $NS1 ip link set $VETH1 up
echo "$NS1 内接口状态："
ip netns exec $NS1 ip link show

ip netns exec $NS2 ip link set lo up
ip netns exec $NS2 ip link set $VETH2 up
echo "$NS2 内接口状态："
ip netns exec $NS2 ip link show

print_section "配置命名空间 IP 地址"
ip netns exec $NS1 ip addr add 10.0.0.1/24 dev $VETH1
ip netns exec $NS2 ip addr add 10.0.0.2/24 dev $VETH2
echo "$NS1 接口 IP："
ip netns exec $NS1 ip addr show dev $VETH1
echo "$NS2 接口 IP："
ip netns exec $NS2 ip addr show dev $VETH2

print_section "测试命名空间连通性（预期失败：不同 VLAN）"
if ip netns exec $NS1 ping -c 3 10.0.0.2; then
    echo "❌ Ping 成功（不符合 VLAN 隔离预期）"
else
    echo "✅ Ping 失败，符合 VLAN 隔离预期"
fi

print_section "查看 Bridge MAC 地址学习表"
bridge fdb show br $BRIDGE

print_section "脚本结束，按 Ctrl+C 退出，自动清理网络配置"
sleep infinity
