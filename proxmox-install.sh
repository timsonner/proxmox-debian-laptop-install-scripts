#!/bin/bash
# =============================================================================
# Proxmox VE installation on Debian 13 Trixie
# System: debian-laptop
# Ethernet interface name: enx083a88566fce  -> vmbr0 bridge (Proxmox management + VM networking)
# Wi-Fi interface name:    wlp0s20f3        -> standalone interface (direct access, fallback mgmt)
#
# Run each section manually and read the notes - do NOT pipe straight to bash.
# Several steps require a reboot between them.
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0: Configuration — edit these variables to match your environment
# ─────────────────────────────────────────────────────────────────────────────

HOSTNAME="debian-laptop"        # keep existing hostname or change it
FQDN="debian-laptop.local"      # fully-qualified domain name for Proxmox

ETH_IFACE="enx083a88566fce"     # your USB/wired ethernet interface
WIFI_IFACE="wlp0s20f3"          # your Wi-Fi interface

# Proxmox management IP (ethernet bridge vmbr0).
# Leave blank to auto-detect from the current DHCP lease on ETH_IFACE at runtime.
# Set USE_DHCP_BRIDGE=true to keep vmbr0 on DHCP permanently (IP may change on reboot).
USE_DHCP_BRIDGE=false   # false = static (auto-detected or override below)
MGMT_IP=""              # e.g. "192.168.x.102" — blank = auto-detect from ETH_IFACE
MGMT_PREFIX=""          # e.g. "24"            — blank = auto-detect
MGMT_GW=""              # e.g. "192.168.x.1"   — blank = auto-detect
MGMT_DNS=""             # e.g. "192.168.x.1"   — blank = auto-detect from /etc/resolv.conf

# Wi-Fi — will use DHCP (managed via wpa_supplicant)
# Fill in your Wi-Fi credentials before running step 4
WIFI_SSID="<SSID>"           # exact SSID (case-sensitive)
WIFI_PSK="<PRESHARED KEY>"      # plaintext passphrase (will NOT be stored in plaintext)
WIFI_HIDDEN=true               # true = hidden/non-broadcast SSID
WIFI_WPA3=true                 # true = WPA3 Personal (SAE); false = WPA2 PSK
WIFI_COUNTRY="US"              # ISO 3166-1 alpha-2 country code for regulatory domain

echo "Configuration looks good. Proceeding..."

# ─────────────────────────────────────────────────────────────────────────────
# Helper: auto-fill blank MGMT_* vars from the current DHCP lease on ETH_IFACE.
# No-op when USE_DHCP_BRIDGE=true or when all vars are already set.
# ─────────────────────────────────────────────────────────────────────────────
detect_eth_network() {
    [[ "$USE_DHCP_BRIDGE" == true ]] && return 0
    [[ -n "$MGMT_IP" && -n "$MGMT_PREFIX" && -n "$MGMT_GW" && -n "$MGMT_DNS" ]] && return 0

    local addr gw dns
    addr=$(ip -4 addr show dev "$ETH_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
    if [[ -z "$addr" ]]; then
        [[ -z "$MGMT_IP" ]] && echo "WARNING: No IPv4 address on $ETH_IFACE — set MGMT_IP/PREFIX/GW/DNS manually or plug in ethernet."
        return 0
    fi

    MGMT_PREFIX="${MGMT_PREFIX:-${addr##*/}}"
    MGMT_IP="${MGMT_IP:-${addr%%/*}}"

    gw=$(ip route show default 2>/dev/null | awk -v i="$ETH_IFACE" '$5==i{print $3}' | head -1)
    [[ -z "$gw" ]] && gw=$(ip route show default 2>/dev/null | awk 'NR==1{print $3}')
    MGMT_GW="${MGMT_GW:-$gw}"

    dns=$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
    MGMT_DNS="${MGMT_DNS:-${dns:-$MGMT_GW}}"

    echo "[detect] ${ETH_IFACE}: IP=${MGMT_IP}/${MGMT_PREFIX}  GW=${MGMT_GW}  DNS=${MGMT_DNS}"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Configure hostname and /etc/hosts
# ─────────────────────────────────────────────────────────────────────────────
step1_hostname() {
    echo "[Step 1] Configuring hostname..."

    detect_eth_network

    hostnamectl set-hostname "$HOSTNAME"

    # Proxmox requires the hostname to resolve to a non-loopback IP.
    # In DHCP mode we fall back to 127.0.1.1 (Debian default); Proxmox will warn but work.
    cp /etc/hosts /etc/hosts.bak

    # Remove any stale entries for this hostname
    sed -i "/^127\.0\.1\.1.*${HOSTNAME}/d" /etc/hosts
    [[ -n "$MGMT_IP" ]] && sed -i "/^${MGMT_IP//./\\.}[[:space:]]/d" /etc/hosts

    if [[ "$USE_DHCP_BRIDGE" == true || -z "$MGMT_IP" ]]; then
        # DHCP mode: use 127.0.1.1; update /etc/hosts manually after first boot
        if ! grep -q "^127\.0\.1\.1.*${HOSTNAME}" /etc/hosts; then
            sed -i "/^127\.0\.0\.1/a 127.0.1.1       ${FQDN} ${HOSTNAME}" /etc/hosts
        fi
        echo "[Step 1] DHCP mode: hostname mapped to 127.0.1.1 — update /etc/hosts after first boot once IP is known"
    else
        if ! grep -q "^${MGMT_IP}" /etc/hosts; then
            sed -i "/^127\.0\.0\.1/a ${MGMT_IP}       ${FQDN} ${HOSTNAME}" /etc/hosts
        fi
    fi

    echo "[Step 1] /etc/hosts is now:"
    cat /etc/hosts
    echo ""
    echo "[Step 1] Verifying hostname resolution (expect non-loopback IP):"
    hostname --ip-address || echo "WARNING: hostname did not resolve as expected"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Install Proxmox VE repository and keyring
# ─────────────────────────────────────────────────────────────────────────────
step2_add_repo() {
    echo "[Step 2] Adding Proxmox VE repository..."

    cat > /etc/apt/sources.list.d/pve-install-repo.sources << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

    echo "[Step 2] Downloading Proxmox archive keyring..."
    wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        -O /usr/share/keyrings/proxmox-archive-keyring.gpg

    echo "[Step 2] Verifying keyring checksum..."
    echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" \
        | sha256sum --check

    echo "[Step 2] Updating package lists and upgrading system..."
    apt update && apt full-upgrade -y
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Install Proxmox kernel and REBOOT
# (run step4+ after rebooting into the PVE kernel)
# ─────────────────────────────────────────────────────────────────────────────
step3_install_kernel() {
    echo "[Step 3] Installing Proxmox VE kernel..."
    apt install -y proxmox-default-kernel

    echo ""
    echo "========================================================"
    echo "  REBOOT REQUIRED — boot into the Proxmox VE kernel."
    echo "  After rebooting, run: bash proxmox-install.sh step4"
    echo "========================================================"
    echo ""
    read -rp "Reboot now? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] && systemctl reboot
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Configure networking (switch from NetworkManager to ifupdown2)
# Run this AFTER rebooting into the Proxmox kernel.
# ─────────────────────────────────────────────────────────────────────────────
step4_configure_network() {
    echo "[Step 4] Installing ifupdown2, bridge-utils, wpasupplicant, and isc-dhcp-client..."
    apt install -y ifupdown2 bridge-utils wpasupplicant isc-dhcp-client

    echo "[Step 4] Writing wpa_supplicant config for Wi-Fi (WPA3=$WIFI_WPA3, hidden=$WIFI_HIDDEN)..."
    mkdir -p /etc/wpa_supplicant
    WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf"

    # Build the network block based on WPA3 vs WPA2 settings
    if [[ "$WIFI_WPA3" == true ]]; then
        # WPA3 Personal (SAE)
        # ieee80211w=2 = Management Frame Protection Required (mandatory for WPA3)
        # key_mgmt=SAE disables PSK so only SAE handshakes are attempted
        cat > "$WPA_CONF" << WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WIFI_COUNTRY}

network={
    ssid="${WIFI_SSID}"
    scan_ssid=$( [[ "$WIFI_HIDDEN" == true ]] && echo 1 || echo 0 )
    key_mgmt=SAE
    ieee80211w=2
    psk="${WIFI_PSK}"
    proto=RSN
    pairwise=CCMP
    group=CCMP
}
WPAEOF
    else
        # WPA2 Personal (PSK) — use wpa_passphrase to hash the passphrase
        wpa_passphrase "$WIFI_SSID" "$WIFI_PSK" > "$WPA_CONF"
        # Add scan_ssid=1 for hidden networks
        if [[ "$WIFI_HIDDEN" == true ]]; then
            sed -i '/^\s*ssid=/a\\tscan_ssid=1' "$WPA_CONF"
        fi
        # Prepend the control interface header
        sed -i "1s/^/ctrl_interface=DIR=\/var\/run\/wpa_supplicant GROUP=netdev\nupdate_config=1\ncountry=${WIFI_COUNTRY}\n\n/" "$WPA_CONF"
    fi

    chmod 600 "$WPA_CONF"
    echo "[Step 4] wpa_supplicant config written to $WPA_CONF"

    echo "[Step 4] Writing /etc/network/interfaces..."
    cp /etc/network/interfaces /etc/network/interfaces.bak 2>/dev/null || true
    detect_eth_network

    # Abort early if static mode but we still have no IP — better than writing a broken config.
    if [[ "$USE_DHCP_BRIDGE" != true && -z "$MGMT_IP" ]]; then
        echo "ERROR: USE_DHCP_BRIDGE=false but could not detect an IP on $ETH_IFACE."
        echo "       Either plug in ethernet before running step4, set MGMT_IP/PREFIX/GW/DNS manually,"
        echo "       or set USE_DHCP_BRIDGE=true to use DHCP on vmbr0."
        return 1
    fi

    # ── Base stanzas: loopback + ethernet slave ───────────────────────────
    cat > /etc/network/interfaces << EOF
# Generated for Proxmox VE — $(date)
# Interfaces: ${ETH_IFACE} (ethernet/bridge), ${WIFI_IFACE} (wi-fi)

auto lo
iface lo inet loopback

# ── Ethernet: enslaved into vmbr0 bridge ──────────────────────────────────
# allow-hotplug: non-blocking when cable is unplugged; fires on cable events
allow-hotplug ${ETH_IFACE}
iface ${ETH_IFACE} inet manual
EOF

    # Static mode: explicit route hooks so the default route tracks cable events.
    if [[ "$USE_DHCP_BRIDGE" != true ]]; then
        cat >> /etc/network/interfaces << EOF
        post-up   ip route add default via ${MGMT_GW} metric 100 dev vmbr0 2>/dev/null || true
        pre-down  ip route del default via ${MGMT_GW} dev vmbr0 2>/dev/null || true
EOF
    fi

    # ── vmbr0 stanza: DHCP or static ──────────────────────────────────────
    if [[ "$USE_DHCP_BRIDGE" == true ]]; then
        cat >> /etc/network/interfaces << EOF

# ── vmbr0: Linux bridge for Proxmox management + VM networking (DHCP) ────
auto vmbr0
iface vmbr0 inet dhcp
        bridge-ports ${ETH_IFACE}
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
EOF
    else
        cat >> /etc/network/interfaces << EOF

# ── vmbr0: Linux bridge for Proxmox management + VM networking (static) ──
# Default route managed via ${ETH_IFACE} post-up/pre-down (tracks cable events).
auto vmbr0
iface vmbr0 inet static
        address ${MGMT_IP}/${MGMT_PREFIX}
        dns-nameservers ${MGMT_DNS}
        bridge-ports ${ETH_IFACE}
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        post-up  ip link show ${ETH_IFACE} > /dev/null 2>&1 && ip route add default via ${MGMT_GW} metric 100 dev vmbr0 2>/dev/null || true
        pre-down ip route del default via ${MGMT_GW} dev vmbr0 2>/dev/null || true
EOF
    fi

    # ── Wi-Fi stanza (always DHCP) ────────────────────────────────────────
    cat >> /etc/network/interfaces << EOF

# ── Wi-Fi: standalone DHCP interface (management fallback) ────────────────
# metric 50 makes the DHCP default route preferred over the ethernet metric 100,
# so Wi-Fi provides internet whenever it is up regardless of ethernet state.
# Uses systemd wpa_supplicant@.service instead of ifupdown hook to avoid
# conflicts with the generic wpa_supplicant D-Bus daemon.
auto ${WIFI_IFACE}
iface ${WIFI_IFACE} inet dhcp
        metric 50
        pre-up systemctl start wpa_supplicant@${WIFI_IFACE}.service && sleep 5
        post-down systemctl stop wpa_supplicant@${WIFI_IFACE}.service || true
EOF

    echo "[Step 4] Disabling NetworkManager so ifupdown2 takes over..."
    systemctl disable --now NetworkManager 2>/dev/null || true

    echo ""
    echo "========================================================"
    echo "  Network config written. A reboot will activate it."
    if [[ "$USE_DHCP_BRIDGE" == true ]]; then
        echo "  After reboot, find the Proxmox web UI IP with:"
        echo "    ip addr show vmbr0  — or check your router DHCP leases"
    else
        echo "  After reboot, Proxmox web UI will be at:"
        echo "  https://${MGMT_IP}:8006"
    fi
    echo "========================================================"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Install Proxmox VE packages
# ─────────────────────────────────────────────────────────────────────────────
step5_install_pve() {
    echo "[Step 5] Installing Proxmox VE packages..."
    # postfix: choose 'Local only' if you have no external mail server
    apt install -y proxmox-ve postfix open-iscsi chrony
    sed -i "s/data.status !== 'Active'/false/" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: Remove Debian kernel and os-prober
# ─────────────────────────────────────────────────────────────────────────────
step6_cleanup() {
    echo "[Step 6] Removing Debian stock kernel..."
    # Detect installed Debian kernel packages dynamically rather than hard-coding a version.
    mapfile -t deb_kernels < <(dpkg -l 'linux-image-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}')
    if [[ ${#deb_kernels[@]} -gt 0 ]]; then
        apt remove -y linux-image-amd64 "${deb_kernels[@]}" || true
    else
        apt remove -y linux-image-amd64 || true
    fi
    update-grub

    echo "[Step 6] Removing os-prober..."
    apt remove -y os-prober || true

    echo "[Step 6] Done. Reboot to finalize."
    if [[ "$USE_DHCP_BRIDGE" == true ]]; then
        echo "After reboot: find IP via 'ip addr show vmbr0' then https://<IP>:8006  (login: root, PAM)"
    else
        echo "After reboot: https://${MGMT_IP}:8006  (login: root, PAM realm)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point — call individual steps or 'all' for a full run
# Usage: sudo bash proxmox-install.sh <step1|step2|step3|step4|step5|step6>
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-help}" in
    step1)  step1_hostname ;;
    step2)  step2_add_repo ;;
    step3)  step3_install_kernel ;;
    step4)  step4_configure_network ;;
    step5)  step5_install_pve ;;
    step6)  step6_cleanup ;;
    *)
        echo "Usage: sudo bash $0 <step1|step2|step3|step4|step5|step6>"
        echo ""
        echo "  step1  — Set hostname + /etc/hosts"
        echo "  step2  — Add Proxmox repo, keyring, apt upgrade"
        echo "  step3  — Install Proxmox kernel  [REBOOT after]"
        echo "  step4  — Switch networking to ifupdown2 + configure vmbr0 + Wi-Fi"
        echo "  step5  — Install proxmox-ve packages"
        echo "  step6  — Remove Debian kernel + os-prober  [REBOOT after]"
        ;;
esac
