# Proxmox on a Debian laptop

Shell scripts that install Proxmox VE on Debian 13 (Trixie) and keep Ethernet and Wi-Fi usable at the same time on a laptop.

`vmbr0` bridges the wired interface for the Proxmox web UI and for guests that should sit on the wired LAN. Wi-Fi stays off that bridge and gets its own DHCP address. The Wi-Fi default route uses metric 50 and the Ethernet default route uses metric 100, so Wi-Fi is the preferred uplink when it is connected, while Ethernet stays reachable on `vmbr0`. `wifi-nat-bridge.sh` can add a second bridge, `vmbr1`, that NATs guest traffic out through Wi-Fi.

## Prerequisites

- Debian 13 (Trixie). The installer writes a `trixie` Proxmox repository and downloads the Trixie archive keyring.
- `sudo`. The scripts change the hostname, apt sources, networking, and installed packages.
- `bash`, `apt`, `wget`, and `sha256sum`, which `proxmox-install.sh` calls.
- `python3`, which `eth-dhcp-roam.sh --permanent` and `wifi-nat-bridge.sh` use to edit `/etc/network/interfaces`.
- `iw`, if you want `wifi-nat-bridge.sh` and `wifi-add-ssid.sh` to auto-detect the Wi-Fi interface. Without `iw`, those scripts still list interfaces that have a `/sys/class/net/<iface>/wireless` directory.

`proxmox-install.sh` installs `proxmox-default-kernel`, `ifupdown2`, `bridge-utils`, `wpasupplicant`, `isc-dhcp-client`, `proxmox-ve`, `postfix`, `open-iscsi`, and `chrony`. `wifi-nat-bridge.sh` installs `dnsmasq` and `iptables`.

There is no package build and no test suite.

## Check the scripts

From this repository:

```bash
bash -n proxmox-install.sh
bash -n eth-dhcp-roam.sh
bash -n wifi-nat-bridge.sh
bash -n wifi-add-ssid.sh
bash proxmox-install.sh
```

`bash -n` only parses a file. `bash proxmox-install.sh` with no arguments prints usage and does not change the system. `shellcheck` is not required by this repo.

## Configure the installer

Edit the settings at the top of `proxmox-install.sh` before you run a step. `HOSTNAME`, `FQDN`, `ETH_IFACE`, `USE_DHCP_BRIDGE`, `MGMT_IP`, `MGMT_PREFIX`, `MGMT_GW`, `MGMT_DNS`, `WIFI_SSID`, `WIFI_PSK`, `WIFI_HIDDEN`, `WIFI_WPA3`, and `WIFI_COUNTRY` are assigned in the file, so exporting the same names does not override them.

| Variable | What to set |
| --- | --- |
| `HOSTNAME` | Short hostname (`hostnamectl set-hostname`) |
| `FQDN` | Fully qualified name written into `/etc/hosts` |
| `ETH_IFACE` | Wired interface enslaved to `vmbr0` |
| `WIFI_IFACE` | Wi-Fi interface. It is only mentioned in a comment, so step 4 exits under `set -u` until you assign it |
| `USE_DHCP_BRIDGE` | `false` (the default) keeps a static address on `vmbr0`. `true` keeps `vmbr0` on DHCP |
| `MGMT_IP`, `MGMT_PREFIX`, `MGMT_GW`, `MGMT_DNS` | Static `vmbr0` settings. Leave them empty to copy the current IPv4 address on `ETH_IFACE`, its default gateway, and the first `nameserver` in `/etc/resolv.conf` |
| `WIFI_SSID`, `WIFI_PSK` | Network name and passphrase written for `wpa_supplicant` |
| `WIFI_HIDDEN` | `true` (the default) sets `scan_ssid` for a hidden SSID |
| `WIFI_WPA3` | `true` (the default) uses WPA3 SAE. `false` uses WPA2 and `wpa_passphrase` |
| `WIFI_COUNTRY` | Regulatory country code. The default in the script is `US` |

On the laptop, list interface names and set `ETH_IFACE` and `WIFI_IFACE` to match:

```bash
ip -br link
iw dev
```

Replace the wired interface name already filled in at the top of the script if it is not the interface on this machine.

## Install

Run the steps yourself. The script header says not to pipe it straight to bash. Step 3 reboots into the Proxmox kernel before step 4. Step 4 writes network config and expects another reboot before you rely on it. Step 6 asks you to reboot again after removing the Debian kernel.

```bash
sudo bash proxmox-install.sh step1
sudo bash proxmox-install.sh step2
sudo bash proxmox-install.sh step3
```

Step 3 asks `Reboot now? [y/N]`. After that reboot:

```bash
sudo bash proxmox-install.sh step4
sudo bash proxmox-install.sh step5
sudo bash proxmox-install.sh step6
```

1. **step1** sets the hostname and inserts an `/etc/hosts` line for `FQDN`. Static mode uses `MGMT_IP` when it is known. DHCP mode, or a static run that could not detect an address, uses `127.0.1.1`. The previous file is copied to `/etc/hosts.bak`.
2. **step2** writes `/etc/apt/sources.list.d/pve-install-repo.sources` for `http://download.proxmox.com/debian/pve` suite `trixie` component `pve-no-subscription`, downloads the Trixie keyring, checks its SHA-256, then runs `apt update` and `apt full-upgrade -y`.
3. **step3** installs `proxmox-default-kernel` and can reboot.
4. **step4** installs `ifupdown2`, `bridge-utils`, `wpasupplicant`, and `isc-dhcp-client`. It writes `/etc/wpa_supplicant/wpa_supplicant-<wifi-iface>.conf` with mode `600`, rewrites `/etc/network/interfaces` (saving `interfaces.bak` when that file already exists), and disables NetworkManager. In static mode it stops if `ETH_IFACE` has no IPv4 address and `MGMT_IP` is empty. Plug in Ethernet, fill in `MGMT_*`, or set `USE_DHCP_BRIDGE=true`.
5. **step5** installs `proxmox-ve`, `postfix`, `open-iscsi`, and `chrony`. `postfix` prompts for a mail setup. The script comment says to choose `Local only` when there is no external mail server.
6. **step6** removes installed `linux-image-<version>` packages and `linux-image-amd64`, runs `update-grub`, removes `os-prober`, and tells you to reboot.

After the final reboot, the web UI login is `root` on the PAM realm:

```bash
ip -4 addr show vmbr0
```

Open `https://<vmbr0-address>:8006`. In static mode that address is `MGMT_IP`. In DHCP mode, check the address after boot. The script also prints it at the end of step 4 and step 6 when the address is already known.

## Usage

### Traffic on the host

The interfaces file from step 4 looks like this:

- `ETH_IFACE` is `inet manual` and is a port of `vmbr0` (`bridge-stp off`, `bridge-fd 0`, `bridge-vlan-aware yes`). `allow-hotplug` is set so a missing cable does not block boot.
- `vmbr0` is `inet static` unless `USE_DHCP_BRIDGE=true`, in which case it is `inet dhcp`.
- Static mode adds a default route via `MGMT_GW` on `vmbr0` with metric 100, and deletes that route when the wired interface goes down.
- The Wi-Fi interface is `inet dhcp` with metric 50. `pre-up` starts `wpa_supplicant@<wifi-iface>.service` and waits 5 seconds. `post-down` stops that service.

Attach a guest that must use the wired LAN to `vmbr0`.

### DHCP on an existing static `vmbr0`

`eth-dhcp-roam.sh` requests a lease on the bridge itself, not on the physical port. Guests on `vmbr0` stay bridged.

```bash
sudo bash eth-dhcp-roam.sh
sudo bash eth-dhcp-roam.sh --permanent
sudo bash eth-dhcp-roam.sh --restore
```

- No flag is the same as `--transient`: release the current lease and request another. It does not survive a reboot.
- `--permanent` copies `/etc/network/interfaces` to `/etc/network/interfaces.static-backup` (it asks before replacing an existing backup) and rewrites the `vmbr0` stanza to `inet dhcp`, keeping `bridge-*` options.
- `--restore` copies that backup back and applies it with `ifreload -a`. It fails if the backup file is missing.

`BRIDGE` defaults to `vmbr0`. `INTERFACES_FILE` and `STATIC_BACKUP` override the two paths.

### NAT bridge for guests through Wi-Fi

Run `wifi-nat-bridge.sh` after Proxmox is up. It appends `vmbr1` with `bridge-ports none`, sets `net.ipv4.ip_forward=1`, adds iptables MASQUERADE and forward rules in the bridge `post-up`, and writes `/etc/dnsmasq.d/vmbr1.conf`.

```bash
sudo bash wifi-nat-bridge.sh
```

The script defaults are `WIFI_BRIDGE=vmbr1`, `WIFI_BRIDGE_IP=10.10.0.1/24`, and DHCP addresses `10.10.0.100` through `10.10.0.200` with a 12 hour lease. DNS comes from the Wi-Fi dhclient lease file, then the Wi-Fi default gateway, then the first nameserver in `/etc/resolv.conf`. Pass replacements in the environment when those defaults are wrong:

```bash
sudo WIFI_IFACE=<wifi-iface> \
    WIFI_BRIDGE=vmbr1 \
    WIFI_BRIDGE_IP=<bridge-address>/<prefix> \
    WIFI_DHCP_RANGE_START=<range-start> \
    WIFI_DHCP_RANGE_END=<range-end> \
    bash wifi-nat-bridge.sh
```

In the Proxmox UI, set the guest network device bridge to `vmbr1`.

### Add another Wi-Fi network

`wifi-add-ssid.sh` talks to the running `wpa_supplicant` on `WIFI_IFACE` and saves the network into `/etc/wpa_supplicant/wpa_supplicant-<wifi-iface>.conf`. The control socket must already exist at `/var/run/wpa_supplicant/<wifi-iface>`. If it does not, the script tells you to start `wpa_supplicant@<wifi-iface>.service`.

Interactive prompts:

```bash
sudo bash wifi-add-ssid.sh
```

Flags (leave off `--wpa3` for WPA2, `--hidden` for a broadcast SSID, and `--connect` to save without switching):

```bash
sudo bash wifi-add-ssid.sh \
    --iface <wifi-iface> \
    --ssid <ssid> \
    --psk <passphrase> \
    --wpa3 \
    --hidden \
    --connect
```

`--connect` selects the new network and, once `wpa_state=COMPLETED`, renews DHCP with `dhclient`. If association does not finish within 15 seconds, the script prints the `wpa_cli select_network` command to retry.

```bash
wpa_cli -i <wifi-iface> status
wpa_cli -i <wifi-iface> list_networks
```

`WIFI-WPA_CLI.md` is the longer `wpa_cli` reference for scan, add, select, disable, remove, and DHCP renew.

## Layout

| Path | Purpose |
| --- | --- |
| `proxmox-install.sh` | Hostname, Proxmox repository, kernel, `vmbr0`, Wi-Fi, packages, Debian kernel removal |
| `eth-dhcp-roam.sh` | One-shot or persistent DHCP on `vmbr0`, and restore of the static backup |
| `wifi-nat-bridge.sh` | Optional `vmbr1` NAT and dnsmasq DHCP for guests via Wi-Fi |
| `wifi-add-ssid.sh` | Add an SSID to the live wpa_supplicant config |
| `WIFI-WPA_CLI.md` | `wpa_cli` command notes for the setup these scripts create |

## License

This repository has no license file.
