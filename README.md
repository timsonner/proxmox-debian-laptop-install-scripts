# Proxmox on a Laptop

Scripts for installing and running Proxmox on a Debian laptop, with support for both Ethernet and Wi-Fi depending on how the device is connected.

## Scripts

### `proxmox-install.sh` — Install Proxmox

Installs Proxmox VE on Debian 13 and configures networking for Ethernet and Wi-Fi.

1. Edit the variables at the top of the script — interface names, Wi-Fi credentials, hostname, fqdn, and whether to use a fixed or automatic IP.
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
- **Ethernet** > attach VMs to `vmbr0`
- **Wi-Fi only** > attach VMs to `vmbr1` (requires `wifi-nat-bridge.sh`)

Go to: VM > Hardware > Network Device > change the bridge.

### `wifi-nat-bridge.sh` — VM Internet over Wi-Fi (Optional)

Creates a second bridge (`vmbr1`) that routes VM traffic through Wi-Fi using NAT. Run this after Proxmox is installed, then attach VMs to `vmbr1` in the Proxmox GUI.

```bash
sudo bash wifi-nat-bridge.sh
```

## Network Layout

```
Ethernet  >  vmbr0  >  Proxmox UI + VMs (when plugged in)
Wi-Fi     >  vmbr1  >  Proxmox UI + VMs (when unplugged, optional)
```

## Troubleshooting

```bash
ip link                            # list interface names
ip addr show                       # show current IPs
wpa_cli -i wlp0s20f3 status        # check Wi-Fi connection
ifdown wlp0s20f3 && ifup wlp0s20f3 # bounce the Wi-Fi interface
```

**Manually configure an ethenet  interface**
```bash
ip addr add 192.168.1.100/24 dev ens18         # assign ip to interface
ip link set dev ens18 up                       # bring interface up
ip route add default via 192.168.1.1 dev ens18 # assign default route to interface
```

> To make changes permanent, edit `/etc/network/interfaces` or use `eth-dhcp-roam.sh`.

See `WIFI-WPA_CLI.md` for reference commands to scan, connect, and switch Wi-Fi networks live.

## Optional - Patch (removes) "No valid subscription" pop-up >= v9.1.2
```bash
# Bakup proxmoxlib.js
cp /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.bak

# Patch subscription check if statement to always return false (which means subscribed)
sed -i "s/res\.data\.status\.toLowerCase() !== 'active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

# Restart the web service (note: clear browser cache or open incognito/private window to verify changes)
systemctl restart pveproxy 
```
