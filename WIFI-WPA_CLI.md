# Managing Wi-Fi with wpa_cli

`wpa_cli` is the command-line interface to the running `wpa_supplicant` daemon.
Use your active Wi-Fi interface rather than hard-coding one:

```bash
WIFI_IFACE=${WIFI_IFACE:-$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')}
```

On this system the daemon typically runs as `wpa_supplicant@${WIFI_IFACE}.service`
and listens on the control socket at `/var/run/wpa_supplicant/${WIFI_IFACE}`.

> **No reboot or service restart needed** for most changes — `wpa_cli` reconfigures
> the running daemon live and can write changes back to the config file.

---

## Prerequisites

The wpa_supplicant service must be running:

```bash
systemctl status "wpa_supplicant@${WIFI_IFACE}.service"
# Start it if needed:
systemctl start "wpa_supplicant@${WIFI_IFACE}.service"
```

---

## Scan for available networks

```bash
wpa_cli -i "$WIFI_IFACE" scan
sleep 2
wpa_cli -i "$WIFI_IFACE" scan_results
```

Output columns: `BSSID  frequency  signal_level  flags  SSID`

The `flags` column tells you the security type:
- `[WPA2-PSK-CCMP]` — WPA2 Personal
- `[SAE]` or `[WPA3-SAE]` — WPA3 Personal
- `[ESS]` — open (no password)

---

## List already-configured networks

```bash
wpa_cli -i "$WIFI_IFACE" list_networks
```

Output: `network id / ssid / bssid / flags`

---

## Add a new WPA2 network

```bash
# 1. Add a blank network slot — note the id returned (e.g. 1)
wpa_cli -i "$WIFI_IFACE" add_network

# 2. Set the SSID
wpa_cli -i "$WIFI_IFACE" set_network 1 ssid '"MyNetwork"'

# 3. Set the passphrase
wpa_cli -i "$WIFI_IFACE" set_network 1 psk '"MyPassphrase"'

# 4. For a hidden SSID add:
wpa_cli -i "$WIFI_IFACE" set_network 1 scan_ssid 1

# 5. Enable and connect
wpa_cli -i "$WIFI_IFACE" enable_network 1

# 6. Save to /etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf
wpa_cli -i "$WIFI_IFACE" save_config
```

---

## Add a new WPA3 (SAE) network

```bash
wpa_cli -i "$WIFI_IFACE" add_network           # note returned id, e.g. 2

wpa_cli -i "$WIFI_IFACE" set_network 2 ssid '"MyWPA3Network"'
wpa_cli -i "$WIFI_IFACE" set_network 2 key_mgmt SAE
wpa_cli -i "$WIFI_IFACE" set_network 2 ieee80211w 2
wpa_cli -i "$WIFI_IFACE" set_network 2 psk '"MyPassphrase"'
wpa_cli -i "$WIFI_IFACE" set_network 2 proto RSN
wpa_cli -i "$WIFI_IFACE" set_network 2 pairwise CCMP
wpa_cli -i "$WIFI_IFACE" set_network 2 group CCMP

# Hidden SSID:
wpa_cli -i "$WIFI_IFACE" set_network 2 scan_ssid 1

wpa_cli -i "$WIFI_IFACE" enable_network 2
wpa_cli -i "$WIFI_IFACE" save_config
```

---

## Connect to a specific network manually

```bash
# Select by network id
wpa_cli -i "$WIFI_IFACE" select_network 1

# Or reassociate with whatever is highest priority
wpa_cli -i "$WIFI_IFACE" reassociate
```

---

## Check connection status

```bash
wpa_cli -i "$WIFI_IFACE" status
```

Look for `wpa_state=COMPLETED` and `ssid=` / `ip_address=` in the output.

---

## Remove a network

```bash
wpa_cli -i "$WIFI_IFACE" remove_network 1
wpa_cli -i "$WIFI_IFACE" save_config
```

---

## Disable a network without removing it

```bash
wpa_cli -i "$WIFI_IFACE" disable_network 1
wpa_cli -i "$WIFI_IFACE" save_config
```

---

## Interactive shell

Run `wpa_cli -i "$WIFI_IFACE"` without extra arguments to enter an interactive
prompt where all the same commands work without the `-i "$WIFI_IFACE"` prefix:

```
wpa_cli -i "$WIFI_IFACE"
> scan
OK
> scan_results
...
> quit
```

---

## Config file location

`/etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf`

`save_config` writes back to this file. Requires `update_config=1` in the file
header — already set by the install script.

---

## Renewing the DHCP lease after connecting

`wpa_supplicant` handles authentication only — it does not request an IP.
If switching networks, renew the lease manually:

```bash
dhclient -r "$WIFI_IFACE" && dhclient "$WIFI_IFACE"
```

Or bounce the interface via ifupdown:

```bash
ifdown "$WIFI_IFACE" && ifup "$WIFI_IFACE"
```

# Quick switch known Wi-Fi networks
```bash
# list known networks
wpa_cli -i "$WIFI_IFACE" list_networks

# join network
wpa_cli -i "$WIFI_IFACE" select_network <network id>

# check status of interface
wpa_cli -i "$WIFI_IFACE" status

# renew IP lease
dhclient -r "$WIFI_IFACE" && dhclient "$WIFI_IFACE"

# optional bounce
ifdown "$WIFI_IFACE" && ifup "$WIFI_IFACE"

# verify IP
curl ipinfo.io/ip
```

# Quick VM loses IP address
```bash
VM_IFACE=${VM_IFACE:-ens18}

# get an IP
dhclient "$VM_IFACE"

# get dns
resolvectl dns "$VM_IFACE" 9.9.9.9 1.1.1.1
```
