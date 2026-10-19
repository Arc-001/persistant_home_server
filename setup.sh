#!/usr/bin/env bash
# One-shot, re-runnable setup for an Ubuntu LTS laptop as a home server.
# Run at the laptop's console (Wi-Fi gets reconfigured):  sudo ./setup.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR=/etc/homeserver
log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -f $HERE/config.env ]] || die "copy config.env.example to config.env and fill it in"
grep -q '^ID=ubuntu' /etc/os-release || die "this script targets Ubuntu"

install -d -m 700 "$CONF_DIR"
install -m 600 "$HERE/config.env" "$CONF_DIR/config.env"
# shellcheck source=/dev/null
source "$CONF_DIR/config.env"

log "Packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  network-manager wpasupplicant openssh-server curl jq iputils-ping

# ---------------------------------------------------------------- never sleep
log "Disable sleep / lid-close suspend"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
install -d /etc/systemd/logind.conf.d
cat >/etc/systemd/logind.conf.d/homeserver.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF

# ---------------------------------------------------------------- Wi-Fi
log "Hand networking to NetworkManager"
if ! grep -rqs 'renderer: *NetworkManager' /etc/netplan; then
  bak="/etc/netplan.bak-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$bak"
  mv /etc/netplan/*.yaml "$bak"/ 2>/dev/null || true
  echo "old netplan configs moved to $bak"
  printf 'network:\n  version: 2\n  renderer: NetworkManager\n' >/etc/netplan/01-network-manager-all.yaml
  chmod 600 /etc/netplan/01-network-manager-all.yaml
  # Stop cloud-init from rewriting netplan on boot.
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo 'network: {config: disabled}' >/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  fi
  systemctl enable --now NetworkManager
  netplan apply
  sleep 5
fi

cat >/etc/NetworkManager/conf.d/homeserver.conf <<'EOF'
[connection]
# Wi-Fi power saving causes random drops on many laptop chips.
wifi.powersave = 2
EOF
systemctl reload NetworkManager

iface="${WIFI_IFACE:-$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi"{print $1; exit}')}"
[[ -n $iface ]] || die "no wifi device found (driver missing?)"

log "Wi-Fi profile '$WIFI_CON_NAME' on $iface"
nmcli connection delete id "$WIFI_CON_NAME" >/dev/null 2>&1 || true
nmcli connection add type wifi con-name "$WIFI_CON_NAME" ifname "$iface" ssid "$WIFI_SSID" \
  wifi-sec.key-mgmt "$WIFI_KEY_MGMT" wifi-sec.psk "$WIFI_PASSWORD" \
  wifi.hidden "$WIFI_HIDDEN" \
  connection.autoconnect yes \
  connection.autoconnect-retries 0 \
  connection.autoconnect-priority 100 \
  ipv4.method auto ipv6.method auto
# autoconnect-retries 0 = retry forever instead of giving up after 4 tries.
nmcli connection up id "$WIFI_CON_NAME" || echo "warning: could not connect yet, watchdog will keep trying"

# ---------------------------------------------------------------- helpers + timers
log "Install DDNS, watchdog, status helpers"
install -m 755 "$HERE/files/porkbun-ddns.sh"      /usr/local/bin/porkbun-ddns
install -m 755 "$HERE/files/wifi-watchdog.sh"     /usr/local/bin/wifi-watchdog
install -m 755 "$HERE/files/homeserver-status.sh" /usr/local/bin/homeserver-status
for u in porkbun-ddns.service porkbun-ddns.timer wifi-watchdog.service wifi-watchdog.timer battery-limit.service; do
  install -m 644 "$HERE/files/$u" /etc/systemd/system/
done
systemctl daemon-reload
systemctl enable --now wifi-watchdog.timer porkbun-ddns.timer

if [[ ${BATTERY_LIMIT:-0} -gt 0 ]] && compgen -G '/sys/class/power_supply/BAT*/charge_control_end_threshold' >/dev/null; then
  systemctl enable --now battery-limit.service
else
  echo "battery charge limit not supported/disabled, skipping"
fi

# ---------------------------------------------------------------- SSH
log "SSH server"
# Classic always-running sshd instead of Ubuntu's socket activation.
systemctl disable --now ssh.socket 2>/dev/null || true
cat >/etc/ssh/sshd_config.d/10-homeserver.conf <<EOF
PermitRootLogin no
PasswordAuthentication $SSH_PASSWORD_AUTH
KbdInteractiveAuthentication no
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
if [[ -n ${SSH_AUTHORIZED_KEY:-} && -n ${SUDO_USER:-} ]]; then
  home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  install -d -m 700 -o "$SUDO_USER" -g "$SUDO_USER" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  grep -qxF "$SSH_AUTHORIZED_KEY" "$home/.ssh/authorized_keys" || echo "$SSH_AUTHORIZED_KEY" >>"$home/.ssh/authorized_keys"
  chown "$SUDO_USER:$SUDO_USER" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
fi
sshd -t
systemctl enable ssh.service
systemctl restart ssh.service

# ---------------------------------------------------------------- Tailscale
log "Tailscale"
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
install -d /etc/systemd/system/tailscaled.service.d
cat >/etc/systemd/system/tailscaled.service.d/restart.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF
systemctl daemon-reload
systemctl enable --now tailscaled
systemctl restart tailscaled

cat >/etc/sysctl.d/99-tailscale.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system >/dev/null

ts_args=(--reset --hostname="$TS_HOSTNAME")
[[ $TS_SSH == yes ]] && ts_args+=(--ssh)
[[ $TS_EXIT_NODE == yes ]] && ts_args+=(--advertise-exit-node)
[[ -n ${TS_AUTHKEY:-} ]] && ts_args+=(--auth-key="$TS_AUTHKEY")
if [[ $TS_ADVERTISE_LAN == yes ]]; then
  lan=$(ip -4 route show dev "$iface" proto kernel scope link | awk '{print $1; exit}')
  if [[ -n $lan ]]; then
    ts_args+=(--advertise-routes="$lan")
    echo "advertising home LAN $lan"
  else
    echo "warning: no LAN subnet on $iface yet; re-run setup once Wi-Fi is up"
  fi
fi
tailscale up "${ts_args[@]}"
tailscale set --auto-update

# ---------------------------------------------------------------- done
log "First DDNS run"
systemctl start porkbun-ddns.service || echo "DDNS failed, check: journalctl -u porkbun-ddns"

log "Done. Status:"
homeserver-status || true
cat <<'EOF'

MANUAL STEPS LEFT (see README):
  1. Tailscale admin console -> this machine -> "Disable key expiry"
  2. Tailscale admin console -> this machine -> Edit route settings -> approve subnet route
  3. Reboot once and confirm everything comes back: sudo reboot
EOF
