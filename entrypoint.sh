#!/bin/sh

# Copyright (c) 2026 SoftEther VPN Client Contributors
#
# This script manages a SoftEther VPN client inside a container.
# It requires several environment variables (SE_SERVER, SE_HUB, SE_NICNAME,
# SE_USERNAME, SE_PASSWORD). Optional variables control ping intervals,
# reconnect delays, and forcing the VPN default route (SE_DEFAULTROUTE).
#
# The script performs the following steps:
# 1. Starts vpnclient and validates runtime prerequisites.
# 2. Detects the original uplink, resolves the VPN server address,
#    and pins server traffic to the uplink route.
# 3. Creates the virtual adapter and VPN account if they do not exist.
# 4. Establishes the VPN session, acquires network configuration via DHCP,
#    and optionally enforces VPN default routing with policy-based uplink
#    preservation.
# 5. Waits for tunnel stabilization and verifies VPN reachability.
# 6. Maintains a state-driven health monitor that validates connectivity,
#    detects route loss, performs local recovery, and reconnects when
#    recovery is unsuccessful.

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
HEALTH_FAILURE_THRESHOLD="${HEALTH_FAILURE_THRESHOLD:-3}"
HEALTH_FAILURE_COUNT=0

USER_COMMAND="$@"
USER_COMMAND_PID=""
USER_COMMAND_EXECUTED="false"

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

LOG_LEVEL=${LOG_LEVEL:-INFO}
STATE_FILE="/run/vpn.state"
STATE="START"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

debug() {
    [ "${LOG_LEVEL}" = "DEBUG" ] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

cleanup() {
    warn "Shutdown signal received"
    if [ -n "${USER_COMMAND_PID}" ] && kill -0 "${USER_COMMAND_PID}" 2>/dev/null; then
        kill -TERM "${USER_COMMAND_PID}" 2>/dev/null || true
        wait "${USER_COMMAND_PID}" 2>/dev/null || true
    fi
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
    debug "Uplink detected: gateway ${UPLINK_GW} dev ${UPLINK_DEV}"
}

resolve_vpn_server() {
    SERVER_HOST="$(echo "${SE_SERVER}" | cut -d: -f1)"
    VPN_SERVER_IP="$(getent hosts "${SERVER_HOST}" | awk '{print $1}' | head -n1)"
    if [ -z "${VPN_SERVER_IP}" ]; then
        err "Unable to resolve VPN server hostname"
        return 1
    fi
    debug "VPN server resolved: ${SERVER_HOST} -> ${VPN_SERVER_IP}"
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
        debug "Pinned route: ${VPN_SERVER_IP} via ${UPLINK_DEV}"
    else
        warn "Failed route pin: ${VPN_SERVER_IP} via ${UPLINK_DEV}"
    fi
}

execute_user_command() {
    if [ -n "${USER_COMMAND}" ] && [ "${USER_COMMAND_EXECUTED}" = "false" ]; then
        local cmd_name

        cmd_name=$(printf '%s\n' "${USER_COMMAND}" | awk '{print $1}')
        cmd_name=$(basename "${cmd_name}")

        debug "Executing user command: ${USER_COMMAND}"

        (
            eval "${USER_COMMAND}" 2>&1 |
            while IFS= read -r line; do
                log "${cmd_name} | ${line}"
            done
        ) &

        USER_COMMAND_PID=$!
        USER_COMMAND_EXECUTED="true"
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
        debug "Uplink policy routing configured: from ${CONTAINER_IP} via ${UPLINK_GW} dev ${UPLINK_DEV} table ${TABLE_NAME}"
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
            debug "Remove redundant default route: $route"
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
    VPN_ADDR="$(ip -4 addr show "${VPN_INTERFACE}" \
        | awk '/inet / {print $2}' \
        | head -n1)"

    if [ -z "${VPN_ADDR}" ]; then
        err "Unable to detect VPN IP address"
        return 1
    fi

    IP_ONLY="$(echo "${VPN_ADDR}" | cut -d/ -f1)"
    PREFIX="$(echo "${VPN_ADDR}" | cut -d/ -f2)"

    case "${PREFIX}" in
        24)
            VPN_GW="$(echo "${IP_ONLY}" | awk -F. '{print $1"."$2"."$3".1"}')"
            ;;
        16)
            VPN_GW="$(echo "${IP_ONLY}" | awk -F. '{print $1"."$2".0.1"}')"
            ;;
        *)
            err "Unsupported VPN subnet mask: /${PREFIX}"
            return 1
            ;;
    esac

    debug "VPN gateway detected: ${VPN_GW} (from ${VPN_ADDR})"
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

    debug "Requesting DHCP lease"

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
        debug "DHCP assigned IP: ${IP_ADDR}"
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

check_vpn_fast_health() {
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

    if ! ping -c 2 -W "${PING_TIMEOUT}" "${VPN_GW}" >/dev/null 2>&1; then
        echo "Gateway unreachable" >&2
        return 1
    fi

    if [ -n "${SE_DEFAULTROUTE}" ]; then
        if ! ip route show default \
            | grep -q "default via ${VPN_GW} dev ${VPN_INTERFACE}"; then

            echo "Default route missing via VPN" >&2
            return 1
        fi
    fi

    return 0
}

check_vpn_health() {
    if ! check_vpn_fast_health; then
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

set_state() {
    if [ "${STATE}" != "$1" ]; then
        debug "State transition: ${STATE} -> $1"
        STATE="$1"
        echo "$1" > "${STATE_FILE}"
    fi
}

vpn_stabilization() {
    debug "Waiting for tunnel stabilization"
    STABILIZE_START="$(date +%s)"
    LAST_STATE=""
    while true; do
        NOW="$(date +%s)"
        ELAPSED=$((NOW - STABILIZE_START))

        if check_vpn_health >/dev/null 2>&1; then
            PUBLIC_IP="${LAST_PUBLIC_IP}"
            debug "VPN public IP detected: ${PUBLIC_IP}"
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
    HEALTH_REASON="$(check_vpn_fast_health 2>&1)"
    HEALTH_OK=$?
    if [ ${HEALTH_OK} -eq 0 ]; then
        log "Local recovery successful"
        return 0
    else
        REASON="$(echo "${HEALTH_REASON}" | head -n1)"
        warn "Local recovery failed: ${REASON}"
        return 1
    fi
}

network_setup() {
    wait_for_interface || return 1

    request_dhcp || return 1

    detect_vpn_gateway || return 1

    pin_server_route

    if [ -n "${SE_DEFAULTROUTE}" ]; then
        ensure_default_route
    fi

    IP_ADDR="$(ip -4 addr show "${VPN_INTERFACE}" \
        | awk '/inet / {print $2}' \
        | head -n1)"

    log "VPN network ready | ip=${IP_ADDR} | gateway=${VPN_GW}"
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

    VPN_GW=""
    LAST_PUBLIC_IP=""
    LAST_PUBLIC_IP_TIME=0

    ip addr flush dev "${VPN_INTERFACE}" >/dev/null 2>&1 || true

    sleep 2
}

vpn_reconnect() {
    warn "Reconnecting VPN"

    VPN_GW=""
    LAST_PUBLIC_IP=""
    LAST_PUBLIC_IP_TIME=0
    DEFAULT_ROUTE_LOGGED=false

    vpn_disconnect

    return 0
}

precheck() {
    debug "Running preflight checks"

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

    debug "Route to VPN server: ${ROUTE}"
    log "Preflight checks passed"

    return 0
}

log "Starting SoftEther VPN Client | deployment v${SE_VERSION}"

precheck || exit 1

if adapter_exists; then
    debug "Adapter exists: ${SE_NICNAME}"
else
    debug "Creating adapter: ${SE_NICNAME}"
    vpn NicCreate "${SE_NICNAME}" >/dev/null
fi

if account_exists; then
    debug "VPN account exists: ${ACCOUNT_NAME}"
else
    debug "Creating VPN account"
    vpn AccountCreate "${ACCOUNT_NAME}" \
        /SERVER:"${SE_SERVER}" \
        /HUB:"${SE_HUB}" \
        /USERNAME:"${SE_USERNAME}" \
        /NICNAME:"${SE_NICNAME}" >/dev/null
    vpncmd localhost /CLIENT /CMD AccountPasswordSet "${ACCOUNT_NAME}" \
        /PASSWORD:"${SE_PASSWORD}" \
        /TYPE:standard >/dev/null
fi

set_state CONNECT

debug "Starting VPN state machine"

while true; do

    case "${STATE}" in

        CONNECT)
            if vpn_connect; then
                set_state STABILIZE
            else
                err "Connect failed"
                sleep "${RECONNECT_DELAY}"
            fi
            ;;


        STABILIZE)
            if network_setup && vpn_stabilization; then
                set_state HEALTHY
                log "VPN operational"
                execute_user_command
            else
                warn "Stabilization failed"
                set_state RECONNECT
            fi
            ;;


        HEALTHY)
            if check_vpn_fast_health >/dev/null 2>&1; then
                if [ "${HEALTH_FAILURE_COUNT}" -gt 0 ]; then
                    log "Health recovered after ${HEALTH_FAILURE_COUNT} failures"
                fi

                HEALTH_FAILURE_COUNT=0
                sleep "${PING_INTERVAL}"
            else
                HEALTH_FAILURE_COUNT=$((HEALTH_FAILURE_COUNT + 1))

                warn "Health check failed ${HEALTH_FAILURE_COUNT}/${HEALTH_FAILURE_THRESHOLD}"

                if [ "${HEALTH_FAILURE_COUNT}" -ge "${HEALTH_FAILURE_THRESHOLD}" ]; then
                    warn "Health degradation threshold reached"
                    HEALTH_FAILURE_COUNT=0
                    set_state DEGRADED
                else
                    sleep "${PING_INTERVAL}"
                fi
            fi
            ;;


        DEGRADED)
            if local_recovery; then
                set_state HEALTHY
                log "VPN operational"
            else
                set_state RECONNECT
            fi
            ;;


        RECONNECT)
            if vpn_reconnect; then
                set_state CONNECT
            else
                sleep "${RECONNECT_DELAY}"
            fi
        ;;


        *)
            err "Unknown state: ${STATE}"
            exit 1
            ;;

    esac

done