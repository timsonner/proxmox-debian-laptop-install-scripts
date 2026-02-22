#!/bin/bash
# =============================================================================
# Optional: NAT bridge for Wi-Fi — lets VMs reach the Wi-Fi network
# Run this AFTER Proxmox is fully installed and running.
#
# This creates vmbr1 (no physical port), enables IP forwarding, and
# masquerades VM traffic out through the Wi-Fi interface (auto-detected, or set WIFI_IFACE).
# =============================================================================

WIFI_IFACE=""   # leave blank to auto-detect, or set to e.g. "wlp0s20f3"
WIFI_BRIDGE="vmbr1"
WIFI_BRIDGE_IP="10.10.0.1/24"   # private range for VMs on the Wi-Fi bridge
WIFI_DHCP_RANGE_START="10.10.0.100"
WIFI_DHCP_RANGE_END="10.10.0.200"

# Auto-detect Wi-Fi interface if not set
if [[ -z "$WIFI_IFACE" ]]; then
    WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1)
    [[ -z "$WIFI_IFACE" ]] && { echo "ERROR: no Wi-Fi interface detected — set WIFI_IFACE manually"; exit 1; }
    echo "[wifi-nat] Auto-detected Wi-Fi interface: $WIFI_IFACE"
fi

# Detect DNS server from the current system config
DNS_SERVER=$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
DNS_SERVER="${DNS_SERVER:-8.8.8.8}"

echo "[wifi-nat] Appending vmbr1 to /etc/network/interfaces..."

cat >> /etc/network/interfaces << EOF

# ── vmbr1: NAT bridge for Wi-Fi network access ───────────────────────────────
#   VMs attached here get NATed through ${WIFI_IFACE} (Wi-Fi).
#   Assign VMs a static IP in 10.10.0.0/24 or run dnsmasq DHCP (see below).
auto ${WIFI_BRIDGE}
iface ${WIFI_BRIDGE} inet static
        address ${WIFI_BRIDGE_IP}
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up   iptables -t nat -A POSTROUTING -s '10.10.0.0/24' -o ${WIFI_IFACE} -j MASQUERADE
        post-up   iptables -A FORWARD -i ${WIFI_BRIDGE} -o ${WIFI_IFACE} -j ACCEPT
        post-up   iptables -A FORWARD -i ${WIFI_IFACE} -o ${WIFI_BRIDGE} -m state --state RELATED,ESTABLISHED -j ACCEPT
        post-down iptables -t nat -D POSTROUTING -s '10.10.0.0/24' -o ${WIFI_IFACE} -j MASQUERADE
        post-down iptables -D FORWARD -i ${WIFI_BRIDGE} -o ${WIFI_IFACE} -j ACCEPT
        post-down iptables -D FORWARD -i ${WIFI_IFACE} -o ${WIFI_BRIDGE} -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF

echo "[wifi-nat] Making IP forwarding persistent..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p

echo "[wifi-nat] Installing dnsmasq for DHCP on vmbr1..."
apt install -y dnsmasq

cat > /etc/dnsmasq.d/vmbr1.conf << EOF
interface=${WIFI_BRIDGE}
dhcp-range=${WIFI_DHCP_RANGE_START},${WIFI_DHCP_RANGE_END},12h
dhcp-option=3,10.10.0.1
dhcp-option=6,${DNS_SERVER}
EOF

systemctl enable --now dnsmasq
ifup ${WIFI_BRIDGE} 2>/dev/null || true

echo ""
echo "=========================================================="
echo "  vmbr1 is ready. Attach VMs to vmbr1 in the Proxmox UI."
echo "  VMs will get a 10.10.0.x address and route through Wi-Fi."
echo "=========================================================="
