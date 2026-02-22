# Proxmox on a Laptop

Scripts for installing and running **Proxmox VE** on a laptop, with support for both Ethernet and Wi-Fi depending on how the device is connected.

## Scripts

### `proxmox-install.sh` — Install Proxmox

Installs Proxmox VE on Debian 13 and configures networking for Ethernet (`vmbr0` bridge) and Wi-Fi.

1. Edit the variables at the top of the script — interface names, Wi-Fi credentials, and whether to use a fixed or automatic IP.
2. Run each step one at a time:
   ```bash
   sudo bash proxmox-install.sh step1   # set hostname
   sudo bash proxmox-install.sh step2   # add Proxmox repo
   sudo bash proxmox-install.sh step3   # install kernel — REBOOT
   sudo bash proxmox-install.sh step4   # configure networking
   sudo bash proxmox-install.sh step5   # install Proxmox packages
   sudo bash proxmox-install.sh step6   # remove Debian kernel — REBOOT
   ```
3. After the final reboot, access Proxmox at `https://localhost:8006`

### `eth-dhcp-roam.sh` — Roam Between Networks

Switches the Ethernet bridge (`vmbr0`) between a fixed IP and automatic DHCP. Useful when moving between known and unknown networks without rebooting.

```bash
sudo bash eth-dhcp-roam.sh               # grab a DHCP lease once (temporary)
sudo bash eth-dhcp-roam.sh --permanent   # switch to DHCP permanently
sudo bash eth-dhcp-roam.sh --restore     # restore the original fixed IP
```

When switching between Ethernet and Wi-Fi, update each VM's network bridge in the Proxmox GUI:
- **Ethernet** → attach VMs to `vmbr0`
- **Wi-Fi only** → attach VMs to `vmbr1` (requires `wifi-nat-bridge.sh`)

Go to: VM → Hardware → Network Device → change the bridge.

### `wifi-nat-bridge.sh` — VM Internet over Wi-Fi (Optional)

Creates a second bridge (`vmbr1`) that routes VM traffic through Wi-Fi using NAT. Run this after Proxmox is installed, then attach VMs to `vmbr1` in the Proxmox GUI.

```bash
sudo bash wifi-nat-bridge.sh
```

## Network Layout

```
Ethernet  >  vmbr0  >  Proxmox UI + VMs (when docked)
Wi-Fi     >  vmbr1  >  Proxmox UI + VMs (when unplugged, optional)
```

## Troubleshooting

```bash
ip link                            # list interface names
ip addr show                       # show current IPs
wpa_cli -i wlp0s20f3 status        # check Wi-Fi connection
ifdown wlp0s20f3 && ifup wlp0s20f3 # bounce the Wi-Fi interface
sudo dhclient -r vmbr0 && sudo dhclient vmbr0  # renew Ethernet DHCP lease
```

**Manually configure an interface** (if DHCP isn't working or you need a quick fix):
```bash
# Assign a static IP (replace with your values)
ip addr add 192.168.1.100/24 dev ens18

# Bring the interface up
ip link set dev ens18 up

# Add a default route via your gateway
ip route add default via 192.168.1.1
```

> These changes are temporary and will not survive a reboot. To make them permanent, edit `/etc/network/interfaces` or use `eth-dhcp-roam.sh`.

See `WIFI-WPA_CLI.md` for reference commands to scan, connect, and switch Wi-Fi networks live.

