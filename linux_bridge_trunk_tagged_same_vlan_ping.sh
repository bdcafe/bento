#!/bin/bash
set -e

:<<'LOGIC_DIAGRAM'

原理图（Linux Bridge + VLAN tagged 示例，含同 VLAN 互通）:

  +----------------------+                    +----------------------+
  |  Network Namespace   |                    |  Network Namespace   |
  |         nsA          |                    |         nsB          |
  |  +--------------+    |                    |   +--------------+   |
  |  |  veth1 (IP)  |<===+===veth pair===+===>|   |  veth2 (IP)  |   |
  |  +--------------+    |                    |   +--------------+   |
  +----------------------+                    +----------------------+
            |                                             |
         veth1-br                                      veth2-br
    (tagged VLAN 10)                              (tagged VLAN 20)
            |                                             |
            +----------------------+----------------------+
                                   |
                         Linux Bridge br0 (vlan_filtering=1)
                                   |
        VLAN 10 and VLAN 20 are isolated — no communication
                                   |
        +-------------------[ 新增 ]------------------------+
        |                                                   |
   veth3-br (tagged 30)                              veth4-br (tagged 30)
        |                                                   |
  +-----------------------+                     +-----------------------+
  | Network Namespace nsC |                     | Network Namespace nsD |
  | +-------------------+ |                     | +-------------------+ |
  | | veth3.30 (30 网段)| |<------------------->| | veth4.30 (30 网段)| |
  | +-------------------+ |                     | +-------------------+ |
  +-----------------------+                     +-----------------------+
        |                                                   |
      10.0.30.1                                         10.0.30.2

  说明：
  - nsC 与 nsD 都属于 VLAN 30，能互 ping 成功
  - nsA 与 nsB 属于不同 VLAN，不能互通

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

BRIDGE="br0"

# 原有命名空间和端口
NS1="nsA"; VETH1="veth1"; VETH1_BR="veth1-br"; VLAN1=10
NS2="nsB"; VETH2="veth2"; VETH2_BR="veth2-br"; VLAN2=20

# 新增同 VLAN 命名空间和端口
NS3="nsC"; VETH3="veth3"; VETH3_BR="veth3-br"
NS4="nsD"; VETH4="veth4"; VETH4_BR="veth4-br"
VLAN3=30

cleanup() {
    for ns in $NS1 $NS2 $NS3 $NS4; do
        ip netns del $ns 2>/dev/null || true
    done
    for v in $VETH1_BR $VETH2_BR $VETH3_BR $VETH4_BR; do
        ip link set $v down 2>/dev/null || true
    done
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

print_section "创建命名空间 $NS1, $NS2, $NS3, $NS4"
for ns in $NS1 $NS2 $NS3 $NS4; do
    ip netns add $ns
done
echo "当前命名空间列表："
ip netns list

print_section "创建 veth pair 并连接到 bridge"
# nsA - VLAN10
ip link add $VETH1 type veth peer name $VETH1_BR
ip link set $VETH1 netns $NS1
ip link set $VETH1_BR master $BRIDGE
ip link set $VETH1_BR up
echo "主机端口 $VETH1_BR 状态："
ip link show $VETH1_BR

# nsB - VLAN20
ip link add $VETH2 type veth peer name $VETH2_BR
ip link set $VETH2 netns $NS2
ip link set $VETH2_BR master $BRIDGE
ip link set $VETH2_BR up
echo "主机端口 $VETH2_BR 状态："
ip link show $VETH2_BR

# nsC - VLAN30
ip link add $VETH3 type veth peer name $VETH3_BR
ip link set $VETH3 netns $NS3
ip link set $VETH3_BR master $BRIDGE
ip link set $VETH3_BR up
echo "主机端口 $VETH3_BR 状态："
ip link show $VETH3_BR

# nsD - VLAN30
ip link add $VETH4 type veth peer name $VETH4_BR
ip link set $VETH4 netns $NS4
ip link set $VETH4_BR master $BRIDGE
ip link set $VETH4_BR up
echo "主机端口 $VETH4_BR 状态："
ip link show $VETH4_BR

print_section "配置 VLAN（桥接端口为 trunk/tagged, 允许对应 VLAN）"
bridge vlan add vid $VLAN1 dev $VETH1_BR
bridge vlan add vid $VLAN2 dev $VETH2_BR
bridge vlan add vid $VLAN3 dev $VETH3_BR
bridge vlan add vid $VLAN3 dev $VETH4_BR
echo "当前 VLAN 配置："
bridge vlan show

print_section "启用命名空间接口并创建 VLAN 子接口"
for ns in $NS1 $NS2 $NS3 $NS4; do
    ip netns exec $ns ip link set lo up
done

# nsA: veth1.10
ip netns exec $NS1 ip link set $VETH1 up
ip netns exec $NS1 ip link add link $VETH1 name ${VETH1}.${VLAN1} type vlan id $VLAN1
ip netns exec $NS1 ip link set ${VETH1}.${VLAN1} up
echo "$NS1 内接口状态（含 VLAN 子接口）："
ip netns exec $NS1 ip link show

# nsB: veth2.20
ip netns exec $NS2 ip link set $VETH2 up
ip netns exec $NS2 ip link add link $VETH2 name ${VETH2}.${VLAN2} type vlan id $VLAN2
ip netns exec $NS2 ip link set ${VETH2}.${VLAN2} up
echo "$NS2 内接口状态（含 VLAN 子接口）："
ip netns exec $NS2 ip link show

# nsC: veth3.30
ip netns exec $NS3 ip link set $VETH3 up
ip netns exec $NS3 ip link add link $VETH3 name ${VETH3}.${VLAN3} type vlan id $VLAN3
ip netns exec $NS3 ip link set ${VETH3}.${VLAN3} up
echo "$NS3 内接口状态（含 VLAN 子接口）："
ip netns exec $NS3 ip link show

# nsD: veth4.30
ip netns exec $NS4 ip link set $VETH4 up
ip netns exec $NS4 ip link add link $VETH4 name ${VETH4}.${VLAN3} type vlan id $VLAN3
ip netns exec $NS4 ip link set ${VETH4}.${VLAN3} up
echo "$NS4 内接口状态（含 VLAN 子接口）："
ip netns exec $NS4 ip link show

print_section "配置 VLAN 子接口 IP 地址"
ip netns exec $NS1 ip addr add 10.0.0.1/24 dev ${VETH1}.${VLAN1}
ip netns exec $NS2 ip addr add 10.0.0.2/24 dev ${VETH2}.${VLAN2}
ip netns exec $NS3 ip addr add 10.0.30.1/24 dev ${VETH3}.${VLAN3}
ip netns exec $NS4 ip addr add 10.0.30.2/24 dev ${VETH4}.${VLAN3}

echo "$NS1 VLAN 子接口 IP："
ip netns exec $NS1 ip addr show dev ${VETH1}.${VLAN1}
echo "$NS2 VLAN 子接口 IP："
ip netns exec $NS2 ip addr show dev ${VETH2}.${VLAN2}
echo "$NS3 VLAN 子接口 IP："
ip netns exec $NS3 ip addr show dev ${VETH3}.${VLAN3}
echo "$NS4 VLAN 子接口 IP："
ip netns exec $NS4 ip addr show dev ${VETH4}.${VLAN3}

print_section "测试不同 VLAN 之间连通性（预期失败，隔离）"
if ip netns exec $NS1 ping -c 2 10.0.0.2; then
    echo "❌ Ping 成功（不符合 VLAN 隔离预期）"
else
    echo "✅ Ping 失败，符合 VLAN 隔离预期"
fi

print_section "测试同 VLAN（VLAN 30）连通性（预期成功）"
if ip netns exec $NS3 ping -c 2 10.0.30.2; then
    echo "✅ Ping 成功，符合 VLAN 30 同 VLAN 互通预期"
else
    echo "❌ Ping 失败（不符合预期）"
fi

print_section "脚本结束，按 Ctrl+C 退出，自动清理网络配置"
sleep infinity
