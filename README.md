# Proxmox on a Laptop

Scripts for installing and running Proxmox on a Debian laptop, with a networking layout that keeps both Ethernet and Wi-Fi usable at the same time.

## Scripts

### `proxmox-install.sh` — Install Proxmox

Installs Proxmox VE on Debian 13 and configures networking so:

- `vmbr0` bridges the wired interface and uses DHCP by default
- Wi-Fi stays up as a standalone DHCP uplink with a lower route metric
- Ethernet still provides direct LAN reachability when plugged in
- VMs can optionally use `vmbr1` for Wi-Fi-backed NAT

In the common case, you only need to provide hostname/FQDN and Wi-Fi credentials. The script auto-detects the wired and Wi-Fi interfaces at runtime.

1. Set the values you care about. You can either edit the variables at the top of the script or pass them inline with `sudo env ...`.
   ```bash
   sudo env HOSTNAME=debian-xps-15 \
            FQDN=debian-xps-15.home.arpa \
            WIFI_SSID='MyWiFi' \
            WIFI_PSK='correct horse battery staple' \
            bash proxmox-install.sh step4
   ```
2. Run each step one at a time:
   ```bash
   sudo bash proxmox-install.sh step1   # set hostname
   sudo bash proxmox-install.sh step2   # add Proxmox repo
   sudo bash proxmox-install.sh step3   # install kernel — REBOOT
   sudo bash proxmox-install.sh step4   # configure networking
   sudo bash proxmox-install.sh step5   # install Proxmox packages
   sudo bash proxmox-install.sh step6   # remove Debian kernel — REBOOT
   ```
3. After the networking reboot, find the current management address with:
   ```bash
   ip -br addr show vmbr0
   ```
   Then open `https://<vmbr0-ip>:8006`

### `eth-dhcp-roam.sh` — Roam Between Networks

Switches the Ethernet bridge (`vmbr0`) between a fixed IP and automatic DHCP. This is mainly useful for older static installs; the current default install already keeps `vmbr0` on DHCP permanently.

```bash
sudo bash eth-dhcp-roam.sh               # grab a DHCP lease once (temporary)
sudo bash eth-dhcp-roam.sh --permanent   # switch to DHCP permanently
sudo bash eth-dhcp-roam.sh --restore     # restore the original fixed IP
```

When switching between Ethernet and Wi-Fi, the host itself no longer needs to choose one or the other:
- **Host networking** > Wi-Fi stays the preferred default route, Ethernet stays reachable on `vmbr0`
- **VMs that need the wired LAN** > attach to `vmbr0`
- **VMs that should follow Wi-Fi uplink/NAT** > attach to `vmbr1` (requires `wifi-nat-bridge.sh`)

Go to: VM > Hardware > Network Device > change the bridge.

### `wifi-nat-bridge.sh` — VM Internet over Wi-Fi (Optional)

Creates a second bridge (`vmbr1`) that routes VM traffic through Wi-Fi using NAT. Run this after Proxmox is installed, then attach VMs to `vmbr1` in the Proxmox GUI. The script auto-detects the Wi-Fi uplink and derives DNS from the current Wi-Fi lease when possible.

```bash
sudo bash wifi-nat-bridge.sh
```

## Network Layout

```
Wi-Fi uplink        >  wlp* (auto-detected)  >  preferred default route
Ethernet uplink     >  vmbr0                 >  Proxmox UI + wired LAN access
Optional VM Wi-Fi   >  vmbr1                 >  NAT/DHCP for guests
```

## Troubleshooting

```bash
WIFI_IFACE=${WIFI_IFACE:-$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')}
ip link                            # list interface names
ip addr show                       # show current IPs
wpa_cli -i "$WIFI_IFACE" status    # check Wi-Fi connection
ifdown "$WIFI_IFACE" && ifup "$WIFI_IFACE" # bounce the Wi-Fi interface
```

**Manually configure an ethenet  interface**
```bash
ip addr add 192.168.1.100/24 dev ens18         # assign ip to interface
ip link set dev ens18 up                       # bring interface up
ip route add default via 192.168.1.1 dev ens18 # assign default route to interface
```

> To make changes permanent, edit `/etc/network/interfaces` or rerun the relevant script.

See `WIFI-WPA_CLI.md` for reference commands to scan, connect, and switch Wi-Fi networks live.

### Optional - Patch (removes) "No valid subscription" pop-up >= v9.1.2
```bash
# Bakup proxmoxlib.js
cp /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.bak

# Patch subscription check if statement to always return false (which means subscribed)
sed -i "s/res\.data\.status\.toLowerCase() !== 'active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

# Restart the web service (note: clear browser cache or open incognito/private window to verify changes)
systemctl restart pveproxy 
```

### Optional - Add Proxmox certificate to the Root CA for Chrome/Edge and Firefox

> By default, Proxmox uses a self-signed certificate. Browsers on Linux often ignore the system-wide certificate store and use their own NSS database. To remove the `NET::ERR_CERT_AUTHORITY_INVALID` warning, we import the Proxmox Root CA directly into browser databases.

```bash
apt update
apt install libnss3-tools

# Replace "user" with your actual username (e.g., /home/john/.pki/nssdb)

# Add the certificate to regular user's NSS database (Chrome/Edge)
certutil -d sql:/home/<user>/.pki/nssdb -A -t "C,," -n "Proxmox Root CA" -i /etc/pve/pve-root-ca.pem

# Add the certificate to regular user's NSS database (Firefox). Note: characters in file will be different/randomized.
certutil -d sql:/home/<user>/.mozilla/firefox/<random characters>.default-esr -A -t "C,," -n "Proxmox Root CA" -i /etc/pve/pve-root-ca.pem

# Verify key was added
certutil -d sql:/home/<user>/.pki/nssdb -L | grep "Proxmox"
certutil -d sql:/home/<user>/.mozilla/firefox/<random characters>.default-esr | grep "Proxmox"
```
Close and reopen the browser. Navigate to the Proxmox web interface at `https://localhost:8006` the connection should now be secure and the warning will be gone.

### Optional - Add Proxmox certificate to global certificate store 
This adds the Proxmox certificate to the Linux system's global certificate store which means that system-level tools and command-line utilities will now trust the Proxmox server.
```bash
cp /etc/pve/pve-root-ca.pem /usr/local/share/ca-certificates/pve-root-ca.crt
update-ca-certificates
```
