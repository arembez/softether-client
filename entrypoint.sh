#!/bin/sh

# Copyright (c) 2026 SoftEther VPN Client Contributors
#
# This script manages a SoftEther VPN client inside a container.
# It requires several environment variables (SE_SERVER, SE_HUB, SE_NICNAME,
# SE_USERNAME, SE_PASSWORD). Optional variables control ping intervals,
# reconnect delays, and forcing the VPN default route (SE_DEFAULTROUTE).
#
# The script performs the following steps:
# 1. Starts vpnclient and detects the current uplink (default route).
# 2. Resolves the VPN server IP and pins a route for it via the uplink.
# 3. Creates a virtual network adapter and VPN account if missing.
# 4. Connects to the VPN, obtains an IP via DHCP, and optionally sets the
#    default route through the VPN interface.
# 5. Waits for tunnel stabilization (gateway reachable).
# 6. Runs a health check loop that pings the VPN gateway and reconnects
#    after consecutive failures.

set -u

check_env() {
    : "${SE_SERVER:?missing SE_SERVER}"
    : "${SE_HUB:?missing SE_HUB}"
    : "${SE_NICNAME:?missing SE_NICNAME}"
    : "${SE_USERNAME:?missing SE_USERNAME}"
    : "${SE_PASSWORD:?missing SE_PASSWORD}"
}

PING_INTERVAL="${PING_INTERVAL:-10}"
PING_TIMEOUT="${PING_TIMEOUT:-3}"
RECONNECT_DELAY="${RECONNECT_DELAY:-5}"
MAX_CONNECT_WAIT="${MAX_CONNECT_WAIT:-60}"
INITIAL_STABILIZE_TIMEOUT="${INITIAL_STABILIZE_TIMEOUT:-180}"
INITIAL_STABILIZE_INTERVAL="${INITIAL_STABILIZE_INTERVAL:-10}"
HEALTHCHECK_FAILURES="${HEALTHCHECK_FAILURES:-6}"

SE_DEFAULTROUTE="${SE_DEFAULTROUTE:-}"

ACCOUNT_NAME="${SE_NICNAME}"
VPN_INTERFACE="vpn_${SE_NICNAME}"

UPLINK_GW=""
UPLINK_DEV=""
VPN_SERVER_IP=""
VPN_GW=""
DEFAULT_ROUTE_LOGGED=false
UPLINK_POLICY_LOGGED=false

LAST_PUBLIC_IP=""
LAST_PUBLIC_IP_TIME=0
PUBLIC_IP_CACHE_TTL=30

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

cleanup() {
    warn "Shutdown signal received"
    vpn AccountDisconnect "${ACCOUNT_NAME}" >/dev/null 2>&1 || true
    vpnclient stop >/dev/null 2>&1 || true
    exit 0
}

trap cleanup INT TERM

vpn() {
    vpncmd localhost /CLIENT /CMD "$@" 2>/dev/null \
        | sed '/^vpncmd command/d' \
        | sed '/^SoftEther VPN/d' \
        | sed '/^Developer Edition/d' \
        | sed '/^Version /d' \
        | sed '/^Compiled /d' \
        | sed '/^Copyright /d' \
        | sed '/^Welcome to/d' \
        | sed '/^Please note:/,/^$/d' \
        | sed '/^Connected to VPN Client/d' \
        | sed '/^VPN Client>/d' \
        | sed '/^$/d'
}

detect_uplink() {
    default_route="$(ip route show default | head -n1)"
    if [ -z "${default_route}" ]; then
        err "No default route found – cannot detect uplink interface"
        return 1
    fi
    UPLINK_DEV="$(echo "${default_route}" | awk '{print $5}')"
    UPLINK_GW="$(echo "${default_route}" | awk '{print $3}')"
    if [ -z "${UPLINK_DEV}" ] || [ -z "${UPLINK_GW}" ]; then
        err "Failed to extract gateway or device from default route: ${default_route}"
        return 1
    fi
    log "Uplink detected: gateway ${UPLINK_GW} dev ${UPLINK_DEV}"
}

resolve_vpn_server() {
    SERVER_HOST="$(echo "${SE_SERVER}" | cut -d: -f1)"
    VPN_SERVER_IP="$(getent hosts "${SERVER_HOST}" | awk '{print $1}' | head -n1)"
    if [ -z "${VPN_SERVER_IP}" ]; then
        err "Unable to resolve VPN server hostname"
        return 1
    fi
    log "VPN server resolved: ${SERVER_HOST} -> ${VPN_SERVER_IP}"
}

pin_server_route() {
    [ -z "${VPN_SERVER_IP}" ] && return 1
    [ -z "${UPLINK_GW}" ] && return 1
    [ -z "${UPLINK_DEV}" ] && return 1
    CURRENT_ROUTE="$(ip route show "${VPN_SERVER_IP}" 2>/dev/null || true)"
    EXPECTED_ROUTE="${VPN_SERVER_IP} via ${UPLINK_GW} dev ${UPLINK_DEV}"
    if echo "${CURRENT_ROUTE}" | grep -Fq "${EXPECTED_ROUTE}"; then
        return 0
    fi
    ip route del "${VPN_SERVER_IP}" >/dev/null 2>&1 || true
    if ip route add "${VPN_SERVER_IP}" via "${UPLINK_GW}" dev "${UPLINK_DEV}" >/dev/null 2>&1
    then
        log "Pinned route: ${VPN_SERVER_IP} via ${UPLINK_DEV}"
    else
        warn "Failed route pin: ${VPN_SERVER_IP} via ${UPLINK_DEV}"
    fi
}

setup_uplink_policy() {
    [ -z "${UPLINK_GW}" ] && return 1
    [ -z "${UPLINK_DEV}" ] && return 1

    CONTAINER_IP="$(ip -4 addr show "${UPLINK_DEV}" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
    if [ -z "${CONTAINER_IP}" ]; then
        warn "Cannot detect container IP on ${UPLINK_DEV}, policy routing skipped"
        return 1
    fi

    RT_TABLES="/etc/iproute2/rt_tables"
    if [ ! -f "${RT_TABLES}" ]; then
        mkdir -p "$(dirname "${RT_TABLES}")"
        touch "${RT_TABLES}"
    fi

    TABLE_NAME="original_uplink"
    TABLE_ID=200

    if ! grep -q "^${TABLE_ID} ${TABLE_NAME}" "${RT_TABLES}" 2>/dev/null; then
        echo "${TABLE_ID} ${TABLE_NAME}" >> "${RT_TABLES}"
    fi

    if ! ip route show table "${TABLE_NAME}" | grep -q '^default'; then
        ip route add default via "${UPLINK_GW}" dev "${UPLINK_DEV}" table "${TABLE_NAME}"
    fi

    if ! ip rule show | grep -Fq "from ${CONTAINER_IP} lookup ${TABLE_NAME}"; then
        ip rule add from "${CONTAINER_IP}" lookup "${TABLE_NAME}" priority 1000 >/dev/null 2>&1
    fi

    if [ "${UPLINK_POLICY_LOGGED}" = false ]; then
        log "Uplink policy routing configured: from ${CONTAINER_IP} via ${UPLINK_GW} dev ${UPLINK_DEV} table ${TABLE_NAME}"
        UPLINK_POLICY_LOGGED=true
    fi
}

ensure_default_route() {
    [ -z "${VPN_GW}" ] && return 1

    setup_uplink_policy

    ip route show | grep '^default' | while read -r route; do
        if echo "$route" | grep -q "dev ${VPN_INTERFACE}\>"; then
            continue
        else
            log "Remove redundant default route: $route"
            ip route del $route 2>/dev/null || true
        fi
    done
    if ip route show | grep '^default' | grep -q "dev ${VPN_INTERFACE}\>"; then
        if [ "${DEFAULT_ROUTE_LOGGED}" = false ]; then
            existing_gw="$(ip route show | grep '^default' | grep "dev ${VPN_INTERFACE}" | awk '{print $3}' | head -n1)"
            log "Default route present via VPN gateway ${existing_gw} dev ${VPN_INTERFACE}"
            DEFAULT_ROUTE_LOGGED=true
        fi
    else
        log "Adding default route via VPN gateway ${VPN_GW} dev ${VPN_INTERFACE}"
        ip route add default via "${VPN_GW}" dev "${VPN_INTERFACE}" 2>/dev/null || true
        DEFAULT_ROUTE_LOGGED=false
    fi
}

adapter_exists() {
    vpn NicList | grep -q "${SE_NICNAME}"
}

account_exists() {
    vpn AccountList | grep -A5 "VPN Connection Setting Name *|${ACCOUNT_NAME}" >/dev/null 2>&1
}

is_connected() {
    vpn AccountList \
        | grep -A5 "VPN Connection Setting Name *|${ACCOUNT_NAME}" \
        | grep -q "Status *|Connected"
}

interface_exists() {
    ip link show "${VPN_INTERFACE}" >/dev/null 2>&1
}

has_ip() {
    ip addr show "${VPN_INTERFACE}" 2>/dev/null | grep -q "inet "
}

detect_vpn_gateway() {
    VPN_GW="$(ip route | awk "/${VPN_INTERFACE}/ && /default/ {print \$3}" | head -n1)"
    if [ -z "${VPN_GW}" ]; then
        err "Unable to detect VPN gateway"
        return 1
    fi
    if [ -n "${VPN_GW}" ]; then
        log "VPN gateway detected: ${VPN_GW}"
    fi
}

vpn_public_ip() {
    PUBLIC_IP="$(
        curl -4 \
             --interface "${VPN_INTERFACE}" \
             -s \
             --max-time 10 \
             https://ifconfig.me/ip \
             2>/dev/null || true
    )"

    if [ -z "${PUBLIC_IP}" ]; then
        return 1
    fi

    echo "${PUBLIC_IP}" \
        | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        || return 1

    echo "${PUBLIC_IP}"
    return 0
}

wait_for_interface() {
    i=0
    while [ "$i" -lt 20 ]; do
        if interface_exists; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    err "VPN interface not found"
    return 1
}

request_dhcp() {
    if has_ip; then
        return 0
    fi

    log "Requesting DHCP lease"

    DHCP_OUTPUT="$(udhcpc -i "${VPN_INTERFACE}" -q -n 2>&1)"
    DHCP_EXIT=$?

    if [ ${DHCP_EXIT} -ne 0 ]; then
        err "DHCP failed (exit ${DHCP_EXIT})"
        echo "${DHCP_OUTPUT}" | head -20 | while IFS= read -r line; do
            warn "  ${line}"
        done
        return 1
    fi

    sleep 2

    if has_ip; then
        IP_ADDR="$(ip -4 addr show "${VPN_INTERFACE}" | awk '/inet / {print $2}' | head -n1)"
        log "DHCP assigned IP: ${IP_ADDR}"
        return 0
    fi

    err "DHCP completed but no IP assigned"
    echo "${DHCP_OUTPUT}" | head -20 | while IFS= read -r line; do
        warn "  ${line}"
    done

    return 1
}

wait_until_connected() {
    i=0
    while [ "$i" -lt "$MAX_CONNECT_WAIT" ]; do
        if is_connected; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    err "VPN connection timeout"
    return 1
}

check_vpn_health() {
    if ! is_connected; then
        echo "Connection lost" >&2
        return 1
    fi
    if ! interface_exists; then
        echo "Interface missing" >&2
        return 1
    fi
    if ! has_ip; then
        echo "IP address missing" >&2
        return 1
    fi
    if [ -z "${VPN_GW}" ]; then
        detect_vpn_gateway || {
            echo "Gateway missing" >&2
            return 1
        }
    fi
    if ! ping -c 4 -W "${PING_TIMEOUT}" "${VPN_GW}" >/dev/null 2>&1; then
        echo "Gateway unreachable" >&2
        return 1
    fi

    NOW="$(date +%s)"
    if [ -z "${LAST_PUBLIC_IP}" ] || [ $((NOW - LAST_PUBLIC_IP_TIME)) -ge ${PUBLIC_IP_CACHE_TTL} ]; then
        PUBLIC_IP="$(vpn_public_ip 2>/dev/null || true)"
        if [ -n "${PUBLIC_IP}" ] && echo "${PUBLIC_IP}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            LAST_PUBLIC_IP="${PUBLIC_IP}"
            LAST_PUBLIC_IP_TIME="${NOW}"
        else
            echo "Public IP not available" >&2
            return 1
        fi
    fi

    return 0
}

vpn_stabilization() {
    log "Waiting for tunnel stabilization"
    STABILIZE_START="$(date +%s)"
    LAST_STATE=""
    while true; do
        NOW="$(date +%s)"
        ELAPSED=$((NOW - STABILIZE_START))

        if check_vpn_health >/dev/null 2>&1; then
            PUBLIC_IP="${LAST_PUBLIC_IP}"
            log "VPN public IP detected: ${PUBLIC_IP}"
            if [ -n "${VPN_SERVER_IP}" ] && [ "${PUBLIC_IP}" != "${VPN_SERVER_IP}" ]; then
                warn "VPN public IP (${PUBLIC_IP}) differs from VPN server IP (${VPN_SERVER_IP})"
            fi
            log "Tunnel stabilized | gateway=${VPN_GW} | public_ip=${PUBLIC_IP} | elapsed=${ELAPSED}s"
            return 0
        fi

        REASON="$(check_vpn_health 2>&1 >/dev/null | head -n1)"
        if [ "${REASON}" != "${LAST_STATE}" ] || [ $((ELAPSED % 30)) -eq 0 ]; then
            log "Tunnel stabilizing | state=${REASON} | elapsed=${ELAPSED}s"
            LAST_STATE="${REASON}"
        fi

        if [ "${ELAPSED}" -ge "${INITIAL_STABILIZE_TIMEOUT}" ]; then
            warn "Tunnel stabilization timeout | last_state=${LAST_STATE} | elapsed=${ELAPSED}s"
            return 1
        fi

        sleep "${INITIAL_STABILIZE_INTERVAL}"
    done
}

local_recovery() {
    warn "Attempting local recovery"
    pin_server_route
    if ! interface_exists; then
        warn "VPN interface missing"
        return 1
    fi
    if ! has_ip; then
        warn "IP address lost, requesting DHCP"
        request_dhcp || return 1
    fi
    detect_vpn_gateway || return 1
    if [ -n "${SE_DEFAULTROUTE}" ]; then
        ensure_default_route
    fi
    if check_vpn_health >/dev/null 2>&1; then
        log "Local recovery successful"
        return 0
    else
        REASON="$(check_vpn_health 2>&1 >/dev/null | head -n1)"
        warn "Local recovery failed: ${REASON}"
        return 1
    fi
}

network_setup() {
    wait_for_interface || return 1
    request_dhcp || return 1
    detect_vpn_gateway || return 1
    if [ -n "${SE_DEFAULTROUTE}" ]; then
        ensure_default_route
    fi
    pin_server_route
    IP_ADDR="$(ip -4 addr show "${VPN_INTERFACE}" \
        | awk '/inet / {print $2}' \
        | head -n1)"
    log "VPN network ready | ip=${IP_ADDR} | gateway=${VPN_GW}"
    return 0
}

vpn_connect() {
    pin_server_route
    log "Connecting VPN | server=${SE_SERVER} | hub=${SE_HUB}"
    vpn AccountConnect "${ACCOUNT_NAME}" >/dev/null || true
    if ! wait_until_connected; then
        err "VPN session establishment failed"
        return 1
    fi
    log "VPN session established"
    return 0
}

vpn_disconnect() {
    warn "Disconnecting VPN"
    vpn AccountDisconnect "${ACCOUNT_NAME}" >/dev/null 2>&1 || true
    sleep 2
}

vpn_reconnect() {
    warn "Reconnecting VPN"
    vpn_disconnect
    while true; do
        if vpn_connect && network_setup && vpn_stabilization; then
            DEFAULT_ROUTE_LOGGED=false
            log "Reconnect successful"
            return 0
        fi
        warn "Reconnect failed, retry in ${RECONNECT_DELAY}s"
        sleep "${RECONNECT_DELAY}"
    done
}

precheck() {
    log "Running preflight checks"

    if ! ip link set lo up 2>/dev/null; then
        err "Insufficient privileges for network management"
        return 1
    fi

    check_env || return 1

    for cmd in vpncmd vpnclient ip getent ping awk grep sed udhcpc curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "Required command not found: $cmd"
            return 1
        fi
    done

    vpnclient start >/dev/null 2>&1 || true

    sleep 3

    if ! vpn NicList >/dev/null 2>&1; then
        err "vpnclient is not responding"
        return 1
    fi

    detect_uplink || return 1
    resolve_vpn_server || return 1

    ROUTE="$(ip route get "${VPN_SERVER_IP}" 2>/dev/null | head -n1)"

    if [ -z "${ROUTE}" ]; then
        err "No route to VPN server ${VPN_SERVER_IP}"
        return 1
    fi

    log "Route to VPN server: ${ROUTE}"
    log "Preflight checks passed"

    return 0
}

log "Starting SoftEther VPN Client | deployment v${SE_VERSION}"

precheck || exit 1

if adapter_exists; then
    log "Adapter exists: ${SE_NICNAME}"
else
    log "Creating adapter: ${SE_NICNAME}"
    vpn NicCreate "${SE_NICNAME}" >/dev/null
fi

if account_exists; then
    log "VPN account exists: ${ACCOUNT_NAME}"
else
    log "Creating VPN account"
    vpn AccountCreate "${ACCOUNT_NAME}" \
        /SERVER:"${SE_SERVER}" \
        /HUB:"${SE_HUB}" \
        /USERNAME:"${SE_USERNAME}" \
        /NICNAME:"${SE_NICNAME}" >/dev/null
    vpncmd localhost /CLIENT /CMD AccountPasswordSet "${ACCOUNT_NAME}" \
        /PASSWORD:"${SE_PASSWORD}" \
        /TYPE:standard >/dev/null
fi

until vpn_connect; do
    err "Initial connection failed"
    sleep "${RECONNECT_DELAY}"
done

network_setup || vpn_reconnect

vpn_stabilization || vpn_reconnect

log "Healthcheck started"

FAIL_COUNT=0
LAST_HEALTH_STATE="Healthy"

while true; do
    if check_vpn_health >/dev/null 2>&1; then
        if [ "${LAST_HEALTH_STATE}" != "Healthy" ]; then
            log "Connection restored"
        fi
        FAIL_COUNT=0
        LAST_HEALTH_STATE="Healthy"
        if [ -n "${SE_DEFAULTROUTE}" ]; then
            ensure_default_route
        fi
        pin_server_route
    else
        REASON="$(check_vpn_health 2>&1 >/dev/null | head -n1)"
        if [ "${REASON}" != "${LAST_HEALTH_STATE}" ]; then
            FAIL_COUNT=1
            err "${REASON}"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi

        if [ "${FAIL_COUNT}" -ge "${HEALTHCHECK_FAILURES}" ]; then
            warn "Health check failed ${FAIL_COUNT} times, reconnecting"
            vpn_reconnect
            FAIL_COUNT=0
            LAST_HEALTH_STATE="Healthy"
            sleep "${PING_INTERVAL}"
            continue
        fi
        LAST_HEALTH_STATE="${REASON}"
    fi
    sleep "${PING_INTERVAL}"
done