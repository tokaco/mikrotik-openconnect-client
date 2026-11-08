#!/bin/sh
# Integration test for vpnc-script: creates a real tun device and drives the
# script through connect/disconnect the way openconnect would, then checks the
# routes and NAT rules it installed.
#
# Needs NET_ADMIN and /dev/net/tun, so it runs inside the built image:
#   docker run --rm --cap-add NET_ADMIN --device /dev/net/tun \
#       -v "$PWD/tests:/tests:ro" --entrypoint /bin/sh IMAGE /tests/test-vpnc-script.sh
set -u

fail=0
check() { # check <description> <command...>
    _d="$1"; shift
    if "$@" >/dev/null 2>&1; then printf 'ok    %s\n' "$_d"
    else printf 'FAIL  %s\n' "$_d"; fail=$((fail+1)); fi
}
check_not() {
    _d="$1"; shift
    if "$@" >/dev/null 2>&1; then printf 'FAIL  %s\n' "$_d"; fail=$((fail+1))
    else printf 'ok    %s\n' "$_d"; fi
}
has_route() { ip route show | grep -q "$1"; }
has_nat()   { $IPTABLES -t nat -S POSTROUTING 2>/dev/null | grep -q "$1"; }

# entrypoint.sh exports these after probing; do the same here.
. /dev/null 2>/dev/null || true
IPTABLES=$(for c in iptables-legacy iptables-nft iptables; do
             command -v $c >/dev/null 2>&1 && $c -t nat -L -n >/dev/null 2>&1 && { echo $c; break; }
           done)
[ -n "${IPTABLES:-}" ] || { echo "SKIP: no usable iptables backend in this sandbox"; exit 0; }
export IPTABLES IPTABLES_NAT_TARGET=MASQUERADE
echo "using IPTABLES=$IPTABLES"

ip tuntap add dev tun0 mode tun 2>/dev/null || { echo "SKIP: cannot create tun device"; exit 0; }

# A stand-in for the uplink MikroTik gives the container, so the script has an
# original default route to pin the VPN gateway through.
ip link add veth-test type dummy 2>/dev/null || true
ip addr add 172.17.0.2/24 dev veth-test 2>/dev/null || true
ip link set veth-test up
ip route replace default via 172.17.0.1 dev veth-test

export TUNDEV=tun0
export INTERNAL_IP4_ADDRESS=10.10.10.5
export INTERNAL_IP4_NETMASKLEN=24
export INTERNAL_IP4_MTU=1412
export VPNGATEWAY=45.91.53.233
export reason=connect

echo
echo "== full tunnel (no split routes pushed) =="
/etc/vpnc/vpnc-script >/tmp/out.full 2>&1 || { echo "FAIL: script exited nonzero"; cat /tmp/out.full; fail=$((fail+1)); }
check     "tun0 is up with the VPN address"      ip -o addr show dev tun0 ; \
  ip -o addr show dev tun0 | grep -q '10.10.10.5/24' || { echo "FAIL  tun0 address not 10.10.10.5/24"; fail=$((fail+1)); }
check     "MTU applied (1412)"                   sh -c 'ip -o link show tun0 | grep -q "mtu 1412"'
check     "default route goes to tun0"           sh -c 'ip route show default | grep -q "dev tun0"'
check     "VPN gateway pinned via original uplink" has_route "45.91.53.233 via 172.17.0.1"
check     "NAT rule installed on tun0"           has_nat "\-o tun0"

echo
echo "== disconnect restores the uplink =="
reason=disconnect /etc/vpnc/vpnc-script >/tmp/out.dis 2>&1 || true
check_not "NAT rule removed"                     has_nat "\-o tun0"
check_not "VPN gateway pin removed"              has_route "45.91.53.233 via 172.17.0.1"
check     "original default route restored"      has_route "default via 172.17.0.1"

echo
echo "== split tunnel with an exclude =="
reason=connect
export CISCO_SPLIT_INC=2
export CISCO_SPLIT_INC_0_ADDR=10.20.0.0  CISCO_SPLIT_INC_0_MASKLEN=16
export CISCO_SPLIT_INC_1_ADDR=192.168.77.0 CISCO_SPLIT_INC_1_MASKLEN=24
export CISCO_SPLIT_EXC=1
export CISCO_SPLIT_EXC_0_ADDR=203.0.113.0 CISCO_SPLIT_EXC_0_MASKLEN=24
/etc/vpnc/vpnc-script >/tmp/out.split 2>&1 || { echo "FAIL: script exited nonzero"; cat /tmp/out.split; fail=$((fail+1)); }
check     "split route 1 via tun0"               has_route "10.20.0.0/16 dev tun0"
check     "split route 2 via tun0"               has_route "192.168.77.0/24 dev tun0"
check     "exclude route bypasses the tunnel"    has_route "203.0.113.0/24 via 172.17.0.1"
check_not "default route NOT hijacked in split mode" sh -c 'ip route show default | grep -q "dev tun0"'

echo
echo "== malformed pushed route is rejected, not passed to ip =="
reason=disconnect /etc/vpnc/vpnc-script >/dev/null 2>&1 || true
reason=connect
export CISCO_SPLIT_INC=1
export CISCO_SPLIT_INC_0_ADDR='10.0.0.0; touch /tmp/pwned' CISCO_SPLIT_INC_0_MASKLEN=8
unset CISCO_SPLIT_EXC
/etc/vpnc/vpnc-script >/tmp/out.bad 2>&1 || true
check     "malformed route logged as ignored"    grep -q "ignoring malformed pushed route" /tmp/out.bad
check_not "no command injection from pushed value" test -f /tmp/pwned

echo
echo "failed: $fail"
[ "$fail" -eq 0 ]
