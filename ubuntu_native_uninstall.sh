#!/usr/bin/env bash
# Remove Tor relay instances, systemd services, and optionally VPN/firewall
# and all data/packages installed by ubuntu_native_first_run.sh.
# Run as root: sudo ./ubuntu_native_uninstall.sh [--no-vpn] [--purge]
#   --no-vpn   Skip WireGuard and firewall removal
#   --purge    Also remove relay data directories and optionally packages
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

REMOVE_VPN=1
PURGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-vpn)  REMOVE_VPN=0; shift ;;
    --purge)   PURGE=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Auto-detect instances from systemd service files
INSTANCES=()
while IFS= read -r svc; do
  inst=$(basename "$svc" .service)
  inst="${inst#tor-relay@}"
  INSTANCES+=("$inst")
done < <(find /etc/systemd/system -maxdepth 1 -name 'tor-relay@tor*.service' 2>/dev/null | sort -V)

NUM_RELAYS=${#INSTANCES[@]}
if [[ "$NUM_RELAYS" -lt 1 ]]; then
  echo "No tor-relay@tor*.service files found — nothing to uninstall."
  exit 0
fi

echo "==> Found $NUM_RELAYS relay instance(s): ${INSTANCES[*]}"

# ── 1. Stop and disable all relay services ────────────────────────────
echo "==> Stopping and disabling relay services..."
for inst in "${INSTANCES[@]}"; do
  systemctl stop "tor-relay@${inst}" 2>/dev/null || true
  systemctl disable "tor-relay@${inst}" 2>/dev/null || true
  echo "    Stopped and disabled tor-relay@${inst}"
done

# ── 2. Remove systemd unit files ─────────────────────────────────────
echo "==> Removing systemd unit files..."
for inst in "${INSTANCES[@]}"; do
  rm -f "/etc/systemd/system/tor-relay@${inst}.service"
  echo "    Removed tor-relay@${inst}.service"
done
systemctl daemon-reload

# ── 3. Remove torrc files ────────────────────────────────────────────
echo "==> Removing torrc files..."
for inst in "${INSTANCES[@]}"; do
  rm -f "/etc/tor/${inst}.torrc"
  echo "    Removed /etc/tor/${inst}.torrc"
done

# ── 4. VPN and firewall removal ──────────────────────────────────────
if [[ "$REMOVE_VPN" -eq 1 ]]; then
  echo "==> Removing VPN and firewall..."

  # Stop WireGuard
  if ip link show wg0 &>/dev/null; then
    wg-quick down wg0 2>/dev/null || true
    echo "    WireGuard interface brought down"
  fi
  systemctl disable wg-quick@wg0 2>/dev/null || true

  # Remove firewall script and config
  rm -f /usr/local/sbin/vpn-firewall-rebuild
  rm -rf /etc/vpn-firewall
  echo "    Removed vpn-firewall-rebuild and /etc/vpn-firewall/"

  # Flush nftables rules
  nft flush ruleset 2>/dev/null || true
  echo "    Flushed nftables ruleset"
else
  echo "==> Skipping VPN and firewall removal (--no-vpn)"
fi

# ── 5. Purge data and packages ───────────────────────────────────────
if [[ "$PURGE" -eq 1 ]]; then
  echo ""
  echo "==> Purging relay data directories..."
  for inst in "${INSTANCES[@]}"; do
    rm -rf "/var/lib/tor-instances/${inst}"
    echo "    Removed /var/lib/tor-instances/${inst}"
  done

  echo ""
  read -rp "Remove tor, nftables, and wireguard-tools packages? [y/N] " REMOVE_PKGS || true
  if [[ "${REMOVE_PKGS,,}" == "y" ]]; then
    apt-get remove -y tor deb.torproject.org-keyring nftables wireguard-tools 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/tor.list
    rm -f /usr/share/keyrings/tor-archive-keyring.gpg
    echo "    Packages and Tor Project repository removed"
  fi

  if [[ "$REMOVE_VPN" -eq 1 ]]; then
    read -rp "Remove /etc/wireguard/wg0.conf? [y/N] " REMOVE_WG || true
    if [[ "${REMOVE_WG,,}" == "y" ]]; then
      rm -f /etc/wireguard/wg0.conf
      echo "    Removed /etc/wireguard/wg0.conf"
    fi
  fi
fi

echo ""
echo "==> Uninstall complete. Removed $NUM_RELAYS relay instance(s)."
