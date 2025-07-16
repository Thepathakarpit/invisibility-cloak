#!/bin/bash
set -euo pipefail

# Minimal Full‑System Tor Cloak with redsocks
STATE="$HOME/.torcloak_state"
LOG="$HOME/.torcloak.log"
TORRC="/etc/tor/torrc"
REDSOCKS_CONF="/etc/redsocks.conf"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
error(){ echo "❌ $*" >&2; log "ERROR: $*"; deactivate; exit 1; }

ensure_deps(){
  deps=(tor redsocks iptables sudo curl)
  missing=()
  for cmd in "${deps[@]}";do
    if ! command -v "$cmd" &>/dev/null; then missing+=("$cmd"); fi
  done
  if [ ${#missing[@]} -gt 0 ];then
    log "Installing: ${missing[*]}"
    sudo apt update -y || error "apt update failed"
    sudo DEBIAN_FRONTEND=noninteractive apt install -y "${missing[@]}" \
      || error "apt install failed"
  fi
}

activate(){
  log "Activating Full‑System Tor Cloak"
  ensure_deps

  # 1) Tor config for NAT & DNS
  sudo tee "$TORRC" >/dev/null <<EOF
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 9040
DNSPort 5353
EOF
  sudo systemctl restart tor || error "Failed to start tor"
  sleep 2

  # 2) redsocks config
  sudo tee "$REDSOCKS_CONF" >/dev/null <<EOF
base {
 log_debug = off;
 log_info = on;
 log = "file:$LOG";
 daemon = on;
 redirector = iptables;
}
redsocks {
 local_ip = 127.0.0.1;
 local_port = 12345;
 ip = 127.0.0.1;
 port = 9050;
 type = socks5;
}
EOF
  sudo systemctl restart redsocks || error "Failed to start redsocks"

  # 3) Flush existing rules
  sudo iptables -F
  sudo iptables -t nat -F

  # 4) Redirect DNS (UDP+TCP) → Tor DNSPort
  sudo iptables -t nat -A OUTPUT -p udp --dport 53  -j REDIRECT --to-ports 5353
  sudo iptables -t nat -A OUTPUT -p tcp --dport 53  -j REDIRECT --to-ports 5353

  # 5) Exempt Tor & redsocks themselves
  TOR_UID=$(id -u debian-tor 2>/dev/null||echo 0)
  RED_UID=$(id -u root)
  sudo iptables -t nat -A OUTPUT -m owner --uid-owner $TOR_UID   -j RETURN
  sudo iptables -t nat -A OUTPUT -m owner --uid-owner $RED_UID   -j RETURN
  sudo iptables -t nat -A OUTPUT -d 127.0.0.1/32               -j RETURN

  # 6) Redirect all TCP → redsocks port 12345
  sudo iptables -t nat -A OUTPUT -p tcp --syn               -j REDIRECT --to-ports 12345

  echo active > "$STATE"
  log "✅ Full‑System Tor Cloak activated"
}

deactivate(){
  if [ -f "$STATE" ]; then
    log "Deactivating Tor Cloak"
    sudo systemctl restart tor
    sudo systemctl restart redsocks
    sudo iptables -F
    sudo iptables -t nat -F
    rm -f "$STATE"
    log "✅ Tor Cloak deactivated"
  fi
}

status(){
  if [ -f "$STATE" ]; then
    echo "🎭 Tor Cloak: ACTIVE"
    curl -s https://check.torproject.org/api/ip
  else
    echo "👁️ Tor Cloak: INACTIVE"
    curl -s https://api.ipify.org
  fi
}

case "${1:-activate}" in
  activate)   activate   ;;
  deactivate) deactivate ;;
  status)     status     ;;
  *)          echo "Usage: $0 [activate|deactivate|status]" ; exit 1 ;;
esac

