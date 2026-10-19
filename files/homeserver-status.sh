#!/usr/bin/env bash
# Quick health overview. Run: sudo homeserver-status
for u in tailscaled ssh NetworkManager porkbun-ddns.timer wifi-watchdog.timer; do
  printf '%-22s %s\n' "$u" "$(systemctl is-active "$u")"
done
echo
nmcli -t -f DEVICE,STATE,CONNECTION device | grep -v '^lo:'
echo
tailscale status --self=true --peers=false 2>/dev/null
echo "public IPv4: $(cat /var/lib/porkbun-ddns/last_ip 2>/dev/null || echo unknown)"
echo
journalctl -u porkbun-ddns -u wifi-watchdog -n 10 --no-pager -o short
