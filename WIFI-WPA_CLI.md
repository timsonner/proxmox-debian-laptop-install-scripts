# Managing Wi-Fi with wpa_cli

`wpa_cli` is the command-line interface to the running `wpa_supplicant` daemon.
On this system the daemon runs as `wpa_supplicant@wlp0s20f3.service` and listens
on the control socket at `/var/run/wpa_supplicant/wlp0s20f3`.

> **No reboot or service restart needed** for most changes — `wpa_cli` reconfigures
> the running daemon live and can write changes back to the config file.

---

## Prerequisites

The wpa_supplicant service must be running:

```bash
systemctl status wpa_supplicant@wlp0s20f3.service
# Start it if needed:
systemctl start wpa_supplicant@wlp0s20f3.service
```

---

## Scan for available networks

```bash
wpa_cli -i wlp0s20f3 scan
sleep 2
wpa_cli -i wlp0s20f3 scan_results
```

Output columns: `BSSID  frequency  signal_level  flags  SSID`

The `flags` column tells you the security type:
- `[WPA2-PSK-CCMP]` — WPA2 Personal
- `[SAE]` or `[WPA3-SAE]` — WPA3 Personal
- `[ESS]` — open (no password)

---

## List already-configured networks

```bash
wpa_cli -i wlp0s20f3 list_networks
```

Output: `network id / ssid / bssid / flags`

---

## Add a new WPA2 network

```bash
# 1. Add a blank network slot — note the id returned (e.g. 1)
wpa_cli -i wlp0s20f3 add_network

# 2. Set the SSID
wpa_cli -i wlp0s20f3 set_network 1 ssid '"MyNetwork"'

# 3. Set the passphrase
wpa_cli -i wlp0s20f3 set_network 1 psk '"MyPassphrase"'

# 4. For a hidden SSID add:
wpa_cli -i wlp0s20f3 set_network 1 scan_ssid 1

# 5. Enable and connect
wpa_cli -i wlp0s20f3 enable_network 1

# 6. Save to /etc/wpa_supplicant/wpa_supplicant-wlp0s20f3.conf
wpa_cli -i wlp0s20f3 save_config
```

---

## Add a new WPA3 (SAE) network

```bash
wpa_cli -i wlp0s20f3 add_network           # note returned id, e.g. 2

wpa_cli -i wlp0s20f3 set_network 2 ssid '"MyWPA3Network"'
wpa_cli -i wlp0s20f3 set_network 2 key_mgmt SAE
wpa_cli -i wlp0s20f3 set_network 2 ieee80211w 2
wpa_cli -i wlp0s20f3 set_network 2 psk '"MyPassphrase"'
wpa_cli -i wlp0s20f3 set_network 2 proto RSN
wpa_cli -i wlp0s20f3 set_network 2 pairwise CCMP
wpa_cli -i wlp0s20f3 set_network 2 group CCMP

# Hidden SSID:
wpa_cli -i wlp0s20f3 set_network 2 scan_ssid 1

wpa_cli -i wlp0s20f3 enable_network 2
wpa_cli -i wlp0s20f3 save_config
```

---

## Connect to a specific network manually

```bash
# Select by network id
wpa_cli -i wlp0s20f3 select_network 1

# Or reassociate with whatever is highest priority
wpa_cli -i wlp0s20f3 reassociate
```

---

## Check connection status

```bash
wpa_cli -i wlp0s20f3 status
```

Look for `wpa_state=COMPLETED` and `ssid=` / `ip_address=` in the output.

---

## Remove a network

```bash
wpa_cli -i wlp0s20f3 remove_network 1
wpa_cli -i wlp0s20f3 save_config
```

---

## Disable a network without removing it

```bash
wpa_cli -i wlp0s20f3 disable_network 1
wpa_cli -i wlp0s20f3 save_config
```

---

## Interactive shell

Run `wpa_cli -i wlp0s20f3` without extra arguments to enter an interactive
prompt where all the same commands work without the `-i wlp0s20f3` prefix:

```
wpa_cli -i wlp0s20f3
> scan
OK
> scan_results
...
> quit
```

---

## Config file location

`/etc/wpa_supplicant/wpa_supplicant-wlp0s20f3.conf`

`save_config` writes back to this file. Requires `update_config=1` in the file
header — already set by the install script.

---

## Renewing the DHCP lease after connecting

`wpa_supplicant` handles authentication only — it does not request an IP.
If switching networks, renew the lease manually:

```bash
dhclient -r wlp0s20f3 && dhclient wlp0s20f3
```

Or bounce the interface via ifupdown:

```bash
ifdown wlp0s20f3 && ifup wlp0s20f3
```
