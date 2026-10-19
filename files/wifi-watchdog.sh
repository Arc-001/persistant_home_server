#!/usr/bin/env bash
# Escalating Wi-Fi recovery: reconnect -> restart NetworkManager -> reboot.
set -uo pipefail

# shellcheck source=/dev/null
source /etc/homeserver/config.env

STATE=/run/wifi-watchdog.fails   # tmpfs, resets on reboot
fails=$(cat "$STATE" 2>/dev/null || echo 0)

# Gateway reachable = Wi-Fi is fine (an ISP outage is not our problem to fix).
gw=$(ip -4 route show default | awk '{print $3; exit}')
if [[ -n $gw ]] && ping -c 3 -W 3 "$gw" >/dev/null 2>&1; then
  echo 0 >"$STATE"
  exit 0
fi

fails=$((fails + 1))
echo "$fails" >"$STATE"
echo "gateway unreachable (gw='${gw:-none}'), consecutive failures: $fails"

uptime_s=$(cut -d. -f1 /proc/uptime)
if ((WATCHDOG_REBOOT_AFTER > 0 && fails >= WATCHDOG_REBOOT_AFTER && uptime_s > 1800)); then
  echo "rebooting"
  systemctl reboot
elif ((fails >= 3)); then
  echo "restarting wifi radio + NetworkManager"
  nmcli radio wifi off
  sleep 3
  nmcli radio wifi on
  systemctl restart NetworkManager
else
  echo "re-activating $WIFI_CON_NAME"
  nmcli connection up id "$WIFI_CON_NAME" || true
fi
