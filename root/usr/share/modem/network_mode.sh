#!/bin/sh

PROGRAM="RM520N_NETMODE"

printMsg() {
    local msg="$1"
    logger -t "${PROGRAM}" "${msg}"
}

config_get_or_default() {
    local option="$1"
    local default="$2"
    local value

    value="$(uci -q get "modem.@ndis[0].${option}")"
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

find_device_section() {
    local name="$1"
    local section

    for section in $(uci show network | sed -n 's/^\(network\.[^=]*\)=device$/\1/p'); do
        if [ "$(uci -q get "${section}.name")" = "$name" ]; then
            echo "$section"
            return 0
        fi
    done

    return 1
}

remove_list_entry() {
    local key="$1"
    local value="$2"

    while uci -q del_list "${key}=${value}" 2>/dev/null; do
        :
    done
}

add_unique_list_entry() {
    local key="$1"
    local value="$2"

    remove_list_entry "$key" "$value"
    uci -q add_list "${key}=${value}"
}

reload_network() {
    uci commit network
    /etc/init.d/network reload >/dev/null 2>&1
}

apply_router_mode() {
    local modem_netdev="$1"
    local passthrough_port="$2"
    local lan_bridge_section

    lan_bridge_section="$(find_device_section "br-lan")"
    if [ -n "$lan_bridge_section" ]; then
        add_unique_list_entry "${lan_bridge_section}.ports" "$passthrough_port"
    else
        printMsg "br-lan bridge not found, skipped LAN port restore"
    fi

    uci -q delete network.modem_passthrough_dev
    uci -q delete network.modem_passthrough

    uci -q set network.wan.device="$modem_netdev"
    uci -q set network.wan.proto='dhcp'
    uci -q set network.wan6.device="$modem_netdev"
    uci -q set network.wan6.proto='dhcpv6'
    uci -q set network.wan6.reqaddress='try'
    uci -q set network.wan6.reqprefix='auto'
    uci -q set network.wan6.force_link='1'

    reload_network
    printMsg "Applied router mode on ${modem_netdev}"
}

apply_passthrough_mode() {
    local modem_netdev="$1"
    local passthrough_port="$2"
    local bridge_name="$3"
    local lan_bridge_section

    if [ ! -d "/sys/class/net/${modem_netdev}" ]; then
        printMsg "Modem netdev ${modem_netdev} not found"
    fi

    if [ ! -d "/sys/class/net/${passthrough_port}" ]; then
        printMsg "Passthrough port ${passthrough_port} not found"
    fi

    lan_bridge_section="$(find_device_section "br-lan")"
    if [ -n "$lan_bridge_section" ]; then
        remove_list_entry "${lan_bridge_section}.ports" "$passthrough_port"
    else
        printMsg "br-lan bridge not found, skipped LAN port detach"
    fi

    uci -q delete network.modem_passthrough_dev
    uci -q set network.modem_passthrough_dev='device'
    uci -q set network.modem_passthrough_dev.name="$bridge_name"
    uci -q set network.modem_passthrough_dev.type='bridge'
    uci -q delete network.modem_passthrough_dev.ports
    add_unique_list_entry "network.modem_passthrough_dev.ports" "$modem_netdev"
    add_unique_list_entry "network.modem_passthrough_dev.ports" "$passthrough_port"

    uci -q delete network.modem_passthrough
    uci -q set network.modem_passthrough='interface'
    uci -q set network.modem_passthrough.device="$bridge_name"
    uci -q set network.modem_passthrough.proto='none'

    uci -q set network.wan.device="$bridge_name"
    uci -q set network.wan.proto='none'
    uci -q set network.wan6.device="$bridge_name"
    uci -q set network.wan6.proto='none'

    reload_network
    printMsg "Applied passthrough mode: ${modem_netdev} <-> ${passthrough_port}"
}

MODE="$(config_get_or_default "network_mode" "router")"
MODEM_NETDEV="$(config_get_or_default "modem_netdev" "eth1")"
PASSTHROUGH_PORT="$(config_get_or_default "passthrough_port" "lan4")"
PASSTHROUGH_BRIDGE="$(config_get_or_default "passthrough_bridge" "br-modem")"
ACTION="${1:-apply}"

case "$ACTION" in
    apply|router|passthrough)
        ;;
    *)
        printMsg "Unknown action: ${ACTION}"
        exit 1
        ;;
esac

if [ "$ACTION" = "router" ]; then
    MODE="router"
fi

if [ "$ACTION" = "passthrough" ]; then
    MODE="passthrough"
fi

case "$MODE" in
    passthrough)
        apply_passthrough_mode "$MODEM_NETDEV" "$PASSTHROUGH_PORT" "$PASSTHROUGH_BRIDGE"
        ;;
    *)
        apply_router_mode "$MODEM_NETDEV" "$PASSTHROUGH_PORT"
        ;;
esac
