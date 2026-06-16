#!/bin/sh

STATE_FILE="/run/vpn.state"

[ -f "${STATE_FILE}" ] || exit 1

STATE="$(cat "${STATE_FILE}")"

case "${STATE}" in
    HEALTHY)
        exit 0
        ;;

    STABILIZE)
        exit 0
        ;;

    CONNECT)
        exit 0
        ;;

    DEGRADED|RECONNECT)
        exit 1
        ;;

    *)
        exit 1
        ;;
esac