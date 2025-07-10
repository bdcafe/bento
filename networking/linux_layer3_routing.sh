#!/bin/bash
set -e

:<<'LOGIC_DIAGRAM'

逻辑图（跨命名空间 + 三层路由）:

       +----------------------+                   +----------------------+
       |  Network Namespace   |                   |  Network Namespace   |
       |         nsA          |                   |         nsB          |
       |  +--------------+    |                   |   +--------------+   |
       |  |  veth1 (IP)  |<====+====veth pair====>|   |  veth2 (IP)  |   |
       |  +--------------+    |                   |   +--------------+   |
       +----------------------+                   +----------------------+
                 |                                           |
           +------------+                              +------------+
           | veth1-br   |                              | veth2-br   |
           +------------+                              +------------+
                 |                                           |
           +------------------ Linux Gateway (Routed) ------------------+
                                            |
                                         路由器宿主机
                                            |
                                        启用 IP 转发，执行路由
                                            |
                         +------------------+-------------------+
                         |        命名空间间的通信成功          |

LOGIC_DIAGRAM


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

NS1="nsA"
NS2="nsB"
VETH1="veth1"
VETH1_BR="veth1-br"
VETH2="veth2"
VETH2_BR="veth2-br"

# 各子网及网关配置
NET1="10.0.1.0/24"
NET2="10.0.2.0/24"
GW1="10.0.1.254"
GW2="10.0.2.254"
IP1="10.0.1.1"
IP2="10.0.2.1"

cleanup() {
    ip netns del $NS1 2>/dev/null || true
    ip netns del $NS2 2>/dev/null || true
    ip link set $VETH1_BR down 2>/dev/null || true
    ip link set $VETH2_BR down 2>/dev/null || true
}
trap cleanup EXIT INT
cleanup

print_section "创建命名空间 $NS1 和 $NS2"
ip netns add $NS1
ip netns add $NS2
echo "当前命名空间列表："
ip netns list

print_section "创建 veth pair $VETH1 <-> $VETH1_BR"
ip link add $VETH1 type veth peer name $VETH1_BR
ip link set $VETH1 netns $NS1
ip link set $VETH1_BR up
echo "主机端口 $VETH1_BR 状态："
ip link show $VETH1_BR

print_section "创建 veth pair $VETH2 <-> $VETH2_BR"
ip link add $VETH2 type veth peer name $VETH2_BR
ip link set $VETH2 netns $NS2
ip link set $VETH2_BR up
echo "主机端口 $VETH2_BR 状态："
ip link show $VETH2_BR

print_section "配置 IP 地址"
ip netns exec $NS1 ip addr add $IP1/24 dev $VETH1
ip netns exec $NS2 ip addr add $IP2/24 dev $VETH2
echo "$NS1 IP 地址："
ip netns exec $NS1 ip addr show dev $VETH1
echo "$NS2 IP 地址："
ip netns exec $NS2 ip addr show dev $VETH2

print_section "启用命名空间内接口"
ip netns exec $NS1 ip link set lo up
ip netns exec $NS1 ip link set $VETH1 up
ip netns exec $NS2 ip link set lo up
ip netns exec $NS2 ip link set $VETH2 up
echo "$NS1 内接口状态："
ip netns exec $NS1 ip link show
echo "$NS2 内接口状态："
ip netns exec $NS2 ip link show

print_section "设置桥接端口的 IP 地址（使其充当网关）"
ip addr add $GW1/24 dev $VETH1_BR
ip addr add $GW2/24 dev $VETH2_BR
echo "当前 $VETH1_BR 配置："
ip addr show dev $VETH1_BR
echo "当前 $VETH2_BR 配置："
ip addr show dev $VETH2_BR

print_section "开启宿主机 IP 转发"
sysctl -w net.ipv4.ip_forward=1

print_section "配置跨命名空间路由"
ip netns exec $NS1 ip route add $NET2 via $GW1
ip netns exec $NS2 ip route add $NET1 via $GW2
echo "命名空间 $NS1 路由表："
ip netns exec $NS1 ip route
echo "命名空间 $NS2 路由表："
ip netns exec $NS2 ip route

print_section "测试命名空间连通性（预期成功：三层路由通信）"
if ip netns exec $NS1 ping -c 3 $IP2; then
    echo "✅ Ping 成功，三层交换机已实现跨命名空间通信"
else
    echo "❌ Ping 失败，请检查配置"
fi

print_section "脚本结束，按 Ctrl+C 退出，自动清理网络配置"
sleep infinity
