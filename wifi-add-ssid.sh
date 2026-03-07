#!/bin/bash
# =============================================================================
# wifi-add-ssid.sh — Add a new Wi-Fi SSID to a running wpa_supplicant daemon
#
# Works with the network stack created by proxmox-install.sh.
# Uses wpa_cli to reconfigure the daemon live — no reboot or service
# restart required.  Changes are saved to the wpa_supplicant config file.
#
# Usage (interactive prompts):
#   sudo bash wifi-add-ssid.sh
#
# Usage (non-interactive / scripted):
#   sudo bash wifi-add-ssid.sh \
#       --ssid "MyHotspot" \
#       --psk  "MyPassphrase" \
#       --wpa3 \            # omit for WPA2
#       --hidden \          # omit for broadcast SSID
#       --connect           # immediately switch to this network
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Defaults — auto-detect interface if not overridden
# ─────────────────────────────────────────────────────────────────────────────
WIFI_IFACE=""       # blank = auto-detect
SSID=""
PSK=""
WPA3=false
HIDDEN=false
CONNECT=false

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)"; exit 1; }
}

wpa() {
    wpa_cli -i "$WIFI_IFACE" "$@"
}

detect_iface() {
    if [[ -z "$WIFI_IFACE" ]]; then
        WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1)
        [[ -z "$WIFI_IFACE" ]] && { echo "ERROR: no Wi-Fi interface detected — set WIFI_IFACE manually at the top of the script"; exit 1; }
        echo "[wifi-add-ssid] Auto-detected Wi-Fi interface: $WIFI_IFACE"
    fi
}

check_daemon() {
    local socket="/var/run/wpa_supplicant/${WIFI_IFACE}"
    if [[ ! -S "$socket" ]]; then
        echo "ERROR: wpa_supplicant is not running on $WIFI_IFACE (no socket at $socket)"
        echo "       Start it with: systemctl start wpa_supplicant@${WIFI_IFACE}.service"
        exit 1
    fi
}

print_status() {
    echo ""
    echo "────────────────────────────────────────────"
    echo "  Interface : $WIFI_IFACE"
    echo "  SSID      : $SSID"
    echo "  Security  : $( [[ "$WPA3" == true ]] && echo "WPA3 (SAE)" || echo "WPA2 (PSK)" )"
    echo "  Hidden    : $HIDDEN"
    local ip
    ip=$(ip -4 addr show dev "$WIFI_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
    [[ -n "$ip" ]] && echo "  IP        : $ip"
    echo "────────────────────────────────────────────"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssid)    SSID="$2";    shift 2 ;;
            --psk)     PSK="$2";     shift 2 ;;
            --iface)   WIFI_IFACE="$2"; shift 2 ;;
            --wpa3)    WPA3=true;    shift ;;
            --wpa2)    WPA3=false;   shift ;;
            --hidden)  HIDDEN=true;  shift ;;
            --connect) CONNECT=true; shift ;;
            --help|-h)
                sed -n '2,18p' "$0" | sed 's/^# \?//'
                exit 0
                ;;
            *)
                echo "ERROR: unknown argument: $1"
                echo "       Run with --help for usage."
                exit 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Interactive prompts (only for values not supplied via flags)
# ─────────────────────────────────────────────────────────────────────────────
prompt_missing() {
    if [[ -z "$SSID" ]]; then
        read -rp "SSID (network name): " SSID
        [[ -z "$SSID" ]] && { echo "ERROR: SSID cannot be empty"; exit 1; }
    fi

    if [[ -z "$PSK" ]]; then
        read -rsp "Passphrase: " PSK
        echo ""
        [[ -z "$PSK" ]] && { echo "ERROR: passphrase cannot be empty"; exit 1; }
    fi

    if [[ "$WPA3" == false && "$HIDDEN" == false && "$CONNECT" == false ]]; then
        # Only prompt for extras in fully-interactive mode (no flags given)
        local ans
        read -rp "WPA3 (SAE) security? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] && WPA3=true

        read -rp "Hidden (non-broadcast) SSID? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] && HIDDEN=true

        read -rp "Connect immediately (renew DHCP lease)? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] && CONNECT=true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Add the network via wpa_cli
# ─────────────────────────────────────────────────────────────────────────────
add_network() {
    echo "[wifi-add-ssid] Checking for existing network with SSID \"$SSID\"..."
    local existing
    existing=$(wpa list_networks | awk -F'\t' -v s="$SSID" '$2 == s {print $1}')
    if [[ -n "$existing" ]]; then
        echo "WARNING: SSID \"$SSID\" is already configured as network id $existing."
        read -rp "         Add another entry anyway? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    echo "[wifi-add-ssid] Adding new network slot..."
    local net_id
    net_id=$(wpa add_network)
    echo "[wifi-add-ssid] Assigned network id: $net_id"

    echo "[wifi-add-ssid] Configuring SSID..."
    wpa set_network "$net_id" ssid "\"${SSID}\""

    if [[ "$HIDDEN" == true ]]; then
        echo "[wifi-add-ssid] Marking as hidden SSID (scan_ssid=1)..."
        wpa set_network "$net_id" scan_ssid 1
    fi

    if [[ "$WPA3" == true ]]; then
        echo "[wifi-add-ssid] Applying WPA3 (SAE) settings..."
        wpa set_network "$net_id" key_mgmt SAE
        wpa set_network "$net_id" ieee80211w 2
        wpa set_network "$net_id" psk "\"${PSK}\""
        wpa set_network "$net_id" proto RSN
        wpa set_network "$net_id" pairwise CCMP
        wpa set_network "$net_id" group CCMP
    else
        echo "[wifi-add-ssid] Applying WPA2 (PSK) settings..."
        wpa set_network "$net_id" key_mgmt WPA-PSK
        wpa set_network "$net_id" psk "\"${PSK}\""
    fi

    echo "[wifi-add-ssid] Enabling network $net_id..."
    wpa enable_network "$net_id"

    echo "[wifi-add-ssid] Saving config to wpa_supplicant conf file..."
    wpa save_config

    WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf"
    echo "[wifi-add-ssid] Network saved to $WPA_CONF"

    if [[ "$CONNECT" == true ]]; then
        echo "[wifi-add-ssid] Selecting network $net_id and waiting for association..."
        wpa select_network "$net_id"
        # Poll up to 15 s for WPA auth to complete
        local i=0
        while (( i < 15 )); do
            local state
            state=$(wpa status 2>/dev/null | awk -F= '/^wpa_state/{print $2}')
            [[ "$state" == "COMPLETED" ]] && break
            sleep 1
            (( i++ ))
        done

        local state
        state=$(wpa status 2>/dev/null | awk -F= '/^wpa_state/{print $2}')
        if [[ "$state" != "COMPLETED" ]]; then
            echo "WARNING: Association did not complete within 15 s (state: ${state:-unknown})"
            echo "         Check credentials or signal strength, then run:"
            echo "           wpa_cli -i ${WIFI_IFACE} select_network $net_id"
        else
            echo "[wifi-add-ssid] Associated! Renewing DHCP lease..."
            dhclient -r "$WIFI_IFACE" 2>/dev/null || true
            dhclient "$WIFI_IFACE"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
require_root
parse_args "$@"
detect_iface
check_daemon
prompt_missing
add_network
print_status

echo "Done. To verify:"
echo "  wpa_cli -i ${WIFI_IFACE} status"
echo "  wpa_cli -i ${WIFI_IFACE} list_networks"
