#!/bin/sh
set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <network/CIDR> [interface]"
    echo "Example: $0 192.168.100.0/24"
    echo "Example: $0 192.168.100.0/24 eth0"
    exit 1
fi

NETWORK="$1"

if [ $# -eq 2 ]; then
    INTERFACE="$2"
else
   INTERFACE=$(
        ip -o link show |
        awk -F': ' '{print $2}' |
        sed 's/@.*//' |
        grep -E '^(eth|ens|eno|enp)[[:alnum:]_-]*$' |
        head -n1
    )

    if [ -z "${INTERFACE:-}" ]; then
        echo "Error: Could not find a physical network interface."
        exit 1
    fi

    echo "No interface specified, using first physical interface: $INTERFACE"
fi

# Validate CIDR with a case pattern
case "$NETWORK" in
    *.*.*.*/*) ;;
    *) echo "Error: Network must be in CIDR notation"; exit 1 ;;
esac

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "Error: Interface '$INTERFACE' does not exist."
    exit 1
fi

GATEWAY=$(ip route show dev "$INTERFACE" | grep -m1 ' via ' | awk '{print $3}')

if [ -z "$GATEWAY" ]; then
    GATEWAY=$(ip route show default dev "$INTERFACE" | awk '{print $3; exit}')
fi

if [ -z "$GATEWAY" ]; then
    echo "Error: Could not find any gateway associated with interface '$INTERFACE'."
    exit 1
fi

echo "Using gateway: $GATEWAY on interface $INTERFACE"

if ip route replace "$NETWORK" via "$GATEWAY" dev "$INTERFACE"; then
    echo "Successfully added/replaced route: $NETWORK via $GATEWAY dev $INTERFACE"
else
    echo "Error: Failed to add route."
    exit 1
fi