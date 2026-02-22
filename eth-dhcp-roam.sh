#!/bin/bash
# =============================================================================
# eth-dhcp-roam.sh — Get a DHCP lease on vmbr0 when on an unknown network
#
# Usage:
#   sudo bash eth-dhcp-roam.sh              # one-time DHCP lease (transient)
#   sudo bash eth-dhcp-roam.sh --permanent  # rewrite interfaces to use DHCP
#   sudo bash eth-dhcp-roam.sh --restore    # restore saved static config
#
# Proxmox-safe: uses dhclient directly on vmbr0 (not on the physical port).
# Running VMs on vmbr0 are not affected — the bridge stays up throughout.
# =============================================================================

set -euo pipefail

BRIDGE="vmbr0"
INTERFACES_FILE="/etc/network/interfaces"
STATIC_BACKUP="/etc/network/interfaces.static-backup"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)"; exit 1; }
}

print_status() {
    local ip gw
    ip=$(ip -4 addr show dev "$BRIDGE" | awk '/inet /{print $2}' | head -1)
    gw=$(ip route show default dev "$BRIDGE" 2>/dev/null | awk '{print $3}' | head -1)
    echo ""
    echo "────────────────────────────────────────────"
    echo "  Bridge : $BRIDGE"
    echo "  IP     : ${ip:-<none>}"
    echo "  Gateway: ${gw:-<none>}"
    if [[ -n "$ip" ]]; then
        bare_ip="${ip%%/*}"
        echo "  Web UI : https://${bare_ip}:8006"
    fi
    echo "────────────────────────────────────────────"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MODE: transient — just grab a lease, don't touch interfaces file
# ─────────────────────────────────────────────────────────────────────────────
mode_transient() {
    echo "[dhcp-roam] Releasing any existing lease on $BRIDGE..."
    dhclient -r "$BRIDGE" 2>/dev/null || true

    # Remove any static default route on the bridge so DHCP route wins cleanly
    ip route del default dev "$BRIDGE" 2>/dev/null || true

    echo "[dhcp-roam] Requesting DHCP lease on $BRIDGE..."
    dhclient -v "$BRIDGE" 2>&1 | grep -E "bound|DHCPACK|DHCPNAK|error" || true

    print_status

    echo "NOTE: This lease is transient — it will not survive a reboot."
    echo "      Run with --permanent to write DHCP config to interfaces."
    echo "      Run with --restore  to go back to your saved static config."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODE: permanent — rewrite vmbr0 stanza in interfaces to inet dhcp
# ─────────────────────────────────────────────────────────────────────────────
mode_permanent() {
    if [[ -f "$STATIC_BACKUP" ]]; then
        echo "WARNING: A static backup already exists at $STATIC_BACKUP"
        read -rp "Overwrite it with current interfaces file? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    echo "[dhcp-roam] Backing up current interfaces to $STATIC_BACKUP ..."
    cp "$INTERFACES_FILE" "$STATIC_BACKUP"

    echo "[dhcp-roam] Rewriting $BRIDGE stanza to inet dhcp ..."

    # Use python3 to do a reliable multi-line stanza replacement.
    # Replaces everything from 'iface vmbr0 inet static' up to (but not
    # including) the next 'iface' or 'auto' or 'allow-' line with a clean
    # dhcp stanza, preserving bridge-ports/stp/fd/vlan-aware options.
    python3 << PYEOF
import re, sys

with open("$INTERFACES_FILE") as f:
    content = f.read()

# Extract bridge options we want to keep
bridge_opts = []
in_stanza = False
for line in content.splitlines():
    if re.match(r'iface\s+$BRIDGE\s+inet\s+', line):
        in_stanza = True
        continue
    if in_stanza:
        if re.match(r'(iface|auto|allow-)\s', line):
            break
        stripped = line.strip()
        if stripped.startswith('bridge-'):
            bridge_opts.append('        ' + stripped)

# Build new stanza
new_stanza_lines = [
    'iface $BRIDGE inet dhcp',
]
new_stanza_lines += bridge_opts
new_stanza = '\n'.join(new_stanza_lines)

# Replace old stanza
pattern = r'iface\s+$BRIDGE\s+inet\s+\w+(?:\n(?!(?:iface|auto|allow-)[ \t\n]).*)*'
new_content, n = re.subn(pattern, new_stanza, content)

if n == 0:
    print("ERROR: Could not find $BRIDGE stanza in $INTERFACES_FILE", file=sys.stderr)
    sys.exit(1)

with open("$INTERFACES_FILE", 'w') as f:
    f.write(new_content)

print(f"Replaced {n} stanza(s) successfully.")
PYEOF

    echo "[dhcp-roam] Releasing old lease and requesting new one..."
    dhclient -r "$BRIDGE" 2>/dev/null || true
    ip route del default dev "$BRIDGE" 2>/dev/null || true
    dhclient -v "$BRIDGE" 2>&1 | grep -E "bound|DHCPACK|DHCPNAK|error" || true

    print_status

    echo "Interfaces file updated. This will persist across reboots."
    echo "Run with --restore to go back to your static config."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODE: restore — put the saved static config back
# ─────────────────────────────────────────────────────────────────────────────
mode_restore() {
    if [[ ! -f "$STATIC_BACKUP" ]]; then
        echo "ERROR: No static backup found at $STATIC_BACKUP"
        echo "       Nothing to restore."
        exit 1
    fi

    echo "[dhcp-roam] Restoring static config from $STATIC_BACKUP ..."
    cp "$STATIC_BACKUP" "$INTERFACES_FILE"

    echo "[dhcp-roam] Releasing DHCP lease on $BRIDGE ..."
    dhclient -r "$BRIDGE" 2>/dev/null || true

    echo "[dhcp-roam] Reloading interfaces (Proxmox-safe ifreload)..."
    ifreload -a

    print_status

    echo "Static config restored and applied."
    echo "You may delete the backup: rm $STATIC_BACKUP"
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────
require_root

case "${1:---transient}" in
    --permanent) mode_permanent ;;
    --restore)   mode_restore   ;;
    --transient) mode_transient ;;
    *)
        echo "Usage: sudo bash $0 [--transient|--permanent|--restore]"
        echo ""
        echo "  (no flag)     Grab a one-time DHCP lease on $BRIDGE (transient)"
        echo "  --permanent   Rewrite $BRIDGE to use DHCP in interfaces file"
        echo "  --restore     Restore the saved static config"
        ;;
esac
