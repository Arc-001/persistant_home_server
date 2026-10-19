# Persistent Home Server

Turn an old laptop running Ubuntu LTS into an always-on home server you can reach from college.

| Need | How |
|---|---|
| Tailscale survives reboots | `tailscaled` enabled + `Restart=always`, auto-update on, key expiry disabled (manual step) |
| Stay on home Wi-Fi | NetworkManager profile with infinite autoconnect retries, Wi-Fi power-save off, watchdog timer (reconnect → restart NM → reboot) |
| `4rc.in` follows dynamic IP | `porkbun-ddns.timer` every 5 min, Porkbun API v3 |
| SSH server | `ssh.service` enabled, root login off, optional key-only |
| Reach router remotely | Tailscale **subnet router** (replaces OpenVPN, no port forward needed) |
| Laptop quirks | lid close ignored, sleep masked, battery capped at 80% |

## 1. Prerequisites

1. **Install Ubuntu Server LTS** (Server is better than Desktop here: no GUI, less RAM, GNOME can't suspend it). Connect to Wi-Fi or ethernet during install.
2. **Porkbun API key**
   - porkbun.com → Account → **API Access** → create key (save API key + secret).
   - Domain Management → `4rc.in` → Details → turn on **API ACCESS** for the domain. Without this every call fails.
3. **BIOS** (optional): turn on "power on when AC connected" if the laptop has it, so it boots by itself after a long power cut.

## 2. Install

At the laptop's own keyboard (Wi-Fi gets reconfigured, so an SSH session may drop):

```bash
git clone <this repo> ~/homeserver   # or copy with a USB stick / scp
cd ~/homeserver
cp config.env.example config.env
nano config.env                      # Wi-Fi, Porkbun keys, etc.
sudo ./setup.sh
```

The script is safe to re-run after editing `config.env`.

`tailscale up` prints a login URL if you didn't set `TS_AUTHKEY`. Open it on your phone and log in.

## 3. Manual Tailscale steps (important)

In https://login.tailscale.com/admin/machines → `homeserver` → `...` menu:

1. **Disable key expiry.** If you skip this, the node logs out after ~180 days and you're locked out while away.
2. **Edit route settings → approve** the `192.168.x.0/24` subnet (and exit node if enabled).

Then `sudo reboot` once and check everything comes back: `sudo homeserver-status`.

## 4. Using it from college

- SSH: `ssh you@homeserver` (Tailscale MagicDNS) or `tailscale ssh you@homeserver`.
- Router admin page: open `http://192.168.x.1` in a browser while Tailscale is on.
  - Linux clients must opt in once: `sudo tailscale set --accept-routes`. Phone/Windows/macOS accept routes automatically.
  - If the college network uses the **same subnet** as home (e.g. both `192.168.1.0/24`), routes conflict. Change the home router's LAN subnet to something unusual, like `192.168.77.0/24`.

## 5. CGNAT check (do this before port forwarding)

The DDNS script sets `4rc.in` to the IP the internet sees. Many Indian ISPs (Jio, Airtel) put homes behind **CGNAT**. Then that IP is shared, and inbound connections/port forwards **won't work**, even with correct DNS.

Check: router admin page → WAN/Internet status → WAN IP. Compare with `cat /var/lib/porkbun-ddns/last_ip`.
- Same → you have a real public IP, port forwarding will work.
- Different (often `100.64.x.x`–`100.127.x.x` or `10.x`) → CGNAT. Ask ISP for a public/static IP, or just keep using Tailscale (works either way).

Note: pointing `4rc.in` at home makes your home IP public to anyone who looks up the domain.

## Files

```
setup.sh                    one-shot installer
config.env.example          settings template -> /etc/homeserver/config.env
files/porkbun-ddns.sh       -> /usr/local/bin/porkbun-ddns (+ .service/.timer, every 5 min)
files/wifi-watchdog.sh      -> /usr/local/bin/wifi-watchdog (+ .service/.timer, every 2 min)
files/homeserver-status.sh  -> /usr/local/bin/homeserver-status
files/battery-limit.service caps charge at BATTERY_LIMIT
```

## Troubleshooting

```bash
sudo homeserver-status
journalctl -u porkbun-ddns -n 50
journalctl -u wifi-watchdog -n 50
sudo rm /var/lib/porkbun-ddns/last_ip && sudo systemctl start porkbun-ddns   # force DNS update
nmcli connection show home-wifi | grep autoconnect
```

## Later: real VPN

If you later get a public IP and port forward, WireGuard (e.g. `wg-easy`) is lighter and faster than OpenVPN. You probably won't need it: Tailscale already covers this.
