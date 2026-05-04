#!/bin/bash
# =============================================================================
# Optional: NAT bridge for Wi-Fi — lets VMs reach the network while Wi-Fi
# remains the laptop's upstream/default path.
# Run this AFTER Proxmox is fully installed and running.
#
# This creates vmbr1 (no physical port), enables IP forwarding, and
# masquerades VM traffic out through the Wi-Fi interface (auto-detected, or set WIFI_IFACE).
# =============================================================================

set -euo pipefail

WIFI_IFACE="${WIFI_IFACE:-}"    # blank = auto-detect, or set manually if needed
WIFI_BRIDGE="${WIFI_BRIDGE:-vmbr1}"
WIFI_BRIDGE_IP="${WIFI_BRIDGE_IP:-10.10.0.1/24}"   # private range for VMs on the Wi-Fi bridge
WIFI_DHCP_RANGE_START="${WIFI_DHCP_RANGE_START:-10.10.0.100}"
WIFI_DHCP_RANGE_END="${WIFI_DHCP_RANGE_END:-10.10.0.200}"
INTERFACES_FILE="/etc/network/interfaces"

require_root() {
    [[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)"; exit 1; }
}

list_wifi_ifaces() {
    local iface_path iface

    if command -v iw >/dev/null 2>&1; then
        iw dev 2>/dev/null | awk '/Interface/{print $2}'
    fi

    for iface_path in /sys/class/net/*; do
        iface=${iface_path##*/}
        [[ -d "$iface_path/wireless" ]] && echo "$iface"
    done | awk '!seen[$0]++'
}

detect_wifi_iface() {
    if [[ -z "$WIFI_IFACE" ]]; then
        WIFI_IFACE=$(list_wifi_ifaces | head -1)
        [[ -z "$WIFI_IFACE" ]] && { echo "ERROR: no Wi-Fi interface detected — set WIFI_IFACE manually"; exit 1; }
        echo "[wifi-nat] Auto-detected Wi-Fi interface: $WIFI_IFACE"
    fi
}

derive_bridge_network() {
    local bridge_meta
    bridge_meta=$(python3 - "$WIFI_BRIDGE_IP" <<'PY'
import ipaddress, sys

iface = ipaddress.ip_interface(sys.argv[1])
print(iface.ip)
print(iface.network)
PY
)

    mapfile -t bridge_parts <<< "$bridge_meta"
    WIFI_BRIDGE_GATEWAY="${bridge_parts[0]}"
    WIFI_BRIDGE_CIDR="${bridge_parts[1]}"
}

detect_dns_server() {
    local lease_file="/var/lib/dhcp/dhclient.${WIFI_IFACE}.leases"

    if [[ -f "$lease_file" ]]; then
        DNS_SERVER=$(awk -F'[ ,;]+' '/option domain-name-servers/{print $3; exit}' "$lease_file")
    fi

    if [[ -z "${DNS_SERVER:-}" ]]; then
        DNS_SERVER=$(ip route show default dev "$WIFI_IFACE" 2>/dev/null | awk '{print $3}' | head -1)
    fi

    if [[ -z "${DNS_SERVER:-}" ]]; then
        DNS_SERVER=$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
    fi

    DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
}

remove_existing_bridge_stanza() {
    python3 - "$INTERFACES_FILE" "$WIFI_BRIDGE" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
bridge = sys.argv[2]

if not path.exists():
    raise SystemExit(0)

lines = path.read_text().splitlines()
out = []
i = 0

while i < len(lines):
    line = lines[i]
    if line.strip() == f"auto {bridge}" or line.startswith(f"iface {bridge} "):
        while out and (out[-1].startswith("#") or out[-1].strip() == ""):
            out.pop()

        if line.strip() == f"auto {bridge}":
            i += 1
            if i >= len(lines):
                break
            line = lines[i]

        if line.startswith(f"iface {bridge} "):
            i += 1
            while i < len(lines) and lines[i].startswith((" ", "\t")):
                i += 1
            while i < len(lines) and lines[i].strip() == "":
                i += 1
            continue

    out.append(line)
    i += 1

path.write_text("\n".join(out).rstrip() + ("\n" if out else ""))
PY
}

append_bridge_stanza() {
    cat >> "$INTERFACES_FILE" << EOF

# ── ${WIFI_BRIDGE}: NAT bridge for Wi-Fi network access ─────────────────────
#   VMs attached here get NATed through ${WIFI_IFACE} (Wi-Fi).
auto ${WIFI_BRIDGE}
iface ${WIFI_BRIDGE} inet static
        address ${WIFI_BRIDGE_IP}
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up   iptables -t nat -A POSTROUTING -s '${WIFI_BRIDGE_CIDR}' -o ${WIFI_IFACE} -j MASQUERADE
        post-up   iptables -A FORWARD -i ${WIFI_BRIDGE} -o ${WIFI_IFACE} -j ACCEPT
        post-up   iptables -A FORWARD -i ${WIFI_IFACE} -o ${WIFI_BRIDGE} -m state --state RELATED,ESTABLISHED -j ACCEPT
        post-down iptables -t nat -D POSTROUTING -s '${WIFI_BRIDGE_CIDR}' -o ${WIFI_IFACE} -j MASQUERADE
        post-down iptables -D FORWARD -i ${WIFI_BRIDGE} -o ${WIFI_IFACE} -j ACCEPT
        post-down iptables -D FORWARD -i ${WIFI_IFACE} -o ${WIFI_BRIDGE} -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
}

require_root
detect_wifi_iface
derive_bridge_network
detect_dns_server

echo "[wifi-nat] Updating ${WIFI_BRIDGE} in ${INTERFACES_FILE}..."
remove_existing_bridge_stanza
append_bridge_stanza

echo "[wifi-nat] Making IP forwarding persistent..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
if command -v sysctl >/dev/null 2>&1; then
    sysctl -p
else
    echo 1 > /proc/sys/net/ipv4/ip_forward
fi

echo "[wifi-nat] Installing dnsmasq and iptables for ${WIFI_BRIDGE}..."
apt install -y dnsmasq iptables

cat > /etc/dnsmasq.d/vmbr1.conf << EOF
interface=${WIFI_BRIDGE}
dhcp-range=${WIFI_DHCP_RANGE_START},${WIFI_DHCP_RANGE_END},12h
dhcp-option=3,${WIFI_BRIDGE_GATEWAY}
dhcp-option=6,${DNS_SERVER}
EOF

systemctl enable --now dnsmasq
ifup ${WIFI_BRIDGE} 2>/dev/null || true

echo ""
echo "=========================================================="
echo "  ${WIFI_BRIDGE} is ready. Attach VMs to ${WIFI_BRIDGE} in the Proxmox UI."
echo "  VMs will get a ${WIFI_BRIDGE_CIDR} address and route through Wi-Fi."
echo "=========================================================="
