#!/bin/sh
[ "$1" = "bound" ] || [ "$1" = "renew" ] || exit 0
ip addr flush dev "$interface" 2>/dev/null
ip addr add "$ip/$mask" dev "$interface" 2>/dev/null
[ -n "$router" ] && ip route add default via "$router" dev "$interface" 2>/dev/null
[ -n "$dns" ] && echo "nameserver $dns" > /etc/resolv.conf
