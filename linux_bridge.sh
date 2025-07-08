#!/bin/bash
set -e

# 分隔打印函数，中文也居中
print_section() {
    local msg="$1"
    local width=60
    local edge_line=$(printf '=%.0s' $(seq 1 $width))

    local msg_display_width=$(echo -n "$msg" | awk '{
    len = 0
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c ~ /[一-龥]/) len += 2
      else len += 1
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

print_section "创建 Linux Bridge: $BRIDGE"
ip link add name $BRIDGE type bridge
ip link set dev $BRIDGE up
echo "Bridge $BRIDGE 状态："
ip link show $BRIDGE

print_section "创建命名空间: $NS1, $NS2"
ip netns add $NS1
ip netns add $NS2
echo "当前命名空间列表："
ip netns list

print_section "创建 veth pair: $VETH1 <-> $VETH1_BR"
ip link add $VETH1 type veth peer name $VETH1_BR
ip link set $VETH1 netns $NS1
ip link set $VETH1_BR master $BRIDGE
ip link set $VETH1_BR up
echo "主机端口 $VETH1_BR 状态："
ip link show $VETH1_BR

print_section "创建 veth pair: $VETH2 <-> $VETH2_BR"
ip link add $VETH2 type veth peer name $VETH2_BR
ip link set $VETH2 netns $NS2
ip link set $VETH2_BR master $BRIDGE
ip link set $VETH2_BR up
echo "主机端口 $VETH2_BR 状态："
ip link show $VETH2_BR

print_section "启用命名空间内接口"
ip netns exec $NS1 ip link set lo up
ip netns exec $NS1 ip link set $VETH1 up
echo "$NS1 内接口状态："
ip netns exec $NS1 ip link show

ip netns exec $NS2 ip link set lo up
ip netns exec $NS2 ip link set $VETH2 up
echo "$NS2 内接口状态："
ip netns exec $NS2 ip link show

print_section "配置 IP 地址"
ip netns exec $NS1 ip addr add 10.0.0.1/24 dev $VETH1
ip netns exec $NS2 ip addr add 10.0.0.2/24 dev $VETH2
echo "$NS1 IP 地址："
ip netns exec $NS1 ip addr show dev $VETH1
echo "$NS2 IP 地址："
ip netns exec $NS2 ip addr show dev $VETH2

print_section "测试命名空间间连通性"
if ip netns exec $NS1 ping -c 3 10.0.0.2; then
    echo "✅ Ping 测试成功"
else
    echo "❌ Ping 测试失败"
fi

print_section "Linux Bridge MAC 地址表"
bridge fdb show br $BRIDGE

print_section "脚本结束，按 Ctrl+C 退出，自动清理网络配置"
sleep infinity
