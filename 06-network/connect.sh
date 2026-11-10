#!/usr/bin/env bash
# Connects a network namespace to the bridge lab6 (10.6.0.0/24) the way the CNI
# bridge plugin does: a veth pair with one end in the namespace as eth0 and the
# other on the bridge, an address, a default route, forwarding and NAT outside.
#
# Run as root:
#   ./connect.sh c6a 2           # the namespace of `ip netns add c6a` gets 10.6.0.2
#   ./connect.sh 12345 4         # the network namespace of PID 12345 gets 10.6.0.4
#   ./connect.sh --down          # removes the bridge and the NAT rule
# --down leaves net.ipv4.ip_forward on: other software may rely on it.
set -euo pipefail

br=lab6
net=10.6.0

usage() {
    echo "usage: $0 <PID or ip netns name> <last octet 2-254> | --down" >&2
    exit 1
}

if [ "${1:-}" = "--down" ]; then
    ip link del $br 2> /dev/null || true
    iptables -t nat -D POSTROUTING -s $net.0/24 ! -o $br -j MASQUERADE 2> /dev/null || true
    exit 0
fi
[ $# -eq 2 ] || usage
target=$1
n=$2
if [[ $target =~ ^[0-9]+$ ]]; then
    inside=(nsenter -t "$target" -n)
else
    inside=(ip netns exec "$target")
fi

# the bridge, forwarding and NAT once for all namespaces
if ! ip link show $br > /dev/null 2>&1; then
    ip link add $br type bridge
    ip addr add $net.1/24 dev $br
    ip link set $br up
fi
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s $net.0/24 ! -o $br -j MASQUERADE 2> /dev/null ||
    iptables -t nat -A POSTROUTING -s $net.0/24 ! -o $br -j MASQUERADE

# the veth pair: veth-lab6-<n> on the bridge, eth0 in the namespace
host=veth-$br-$n
ip link add "$host" type veth peer name eth0 netns "$target"
ip link set "$host" master $br
ip link set "$host" up
"${inside[@]}" ip link set lo up
"${inside[@]}" ip addr add $net.$n/24 dev eth0
"${inside[@]}" ip link set eth0 up
"${inside[@]}" ip route add default via $net.1
echo "$target: eth0 $net.$n/24, gateway $net.1"
