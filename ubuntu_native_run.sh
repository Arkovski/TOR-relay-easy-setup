#!/usr/bin/env bash
# Start WireGuard VPN, rebuild firewall, and launch Tor relay instances.
# Run as root: sudo ./ubuntu_native_run.sh [--no-vpn] [--relays N]
#   --no-vpn     Skip WireGuard and firewall (direct port forwarding)
#   --relays N   Number of relay instances (auto-detected if omitted)
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

USE_VPN=1
NUM_RELAYS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-vpn)  USE_VPN=0; shift ;;
    --relays)
      [[ -n "${2:-}" ]] || { echo "ERROR: --relays requires a number" >&2; exit 1; }
      NUM_RELAYS="$2"; shift 2
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Build INSTANCES array: auto-detect from systemd service files, or from --relays
if [[ -z "$NUM_RELAYS" ]]; then
  INSTANCES=()
  while IFS= read -r svc; do
    inst=$(basename "$svc" .service)
    inst="${inst#tor-relay@}"
    INSTANCES+=("$inst")
  done < <(find /etc/systemd/system -maxdepth 1 -name 'tor-relay@tor*.service' 2>/dev/null | sort -V)
  NUM_RELAYS=${#INSTANCES[@]}
  if [[ "$NUM_RELAYS" -lt 1 ]]; then
    echo "ERROR: No tor-relay@tor*.service files found. Run ubuntu_native_first_run.sh first." >&2
    exit 1
  fi
  echo "==> Auto-detected $NUM_RELAYS relay instance(s): ${INSTANCES[*]}"
else
  INSTANCES=()
  for ((i=0; i<NUM_RELAYS; i++)); do
    INSTANCES+=("tor${i}")
  done
fi

# ── 1. Bring up WireGuard ───────────────────────────────────────────
if [[ "$USE_VPN" -eq 1 ]]; then
  if ! ip link show wg0 &>/dev/null; then
    echo "==> Bringing up WireGuard..."
    wg-quick up wg0
  else
    echo "==> WireGuard already up."
  fi

  # ── 2. Rebuild VPN kill-switch firewall ────────────────────────────
  echo "==> Rebuilding firewall..."
  /usr/local/sbin/vpn-firewall-rebuild
else
  echo "==> Skipping WireGuard and firewall (--no-vpn)"
fi

# ── 3. Start Tor relay instances ─────────────────────────────────────
for inst in "${INSTANCES[@]}"; do
  echo "==> Starting ${inst}..."
  systemctl start "tor-relay@${inst}"
done

# ── 4. Status ────────────────────────────────────────────────────────
echo ""
echo "==> Status:"
if [[ "$USE_VPN" -eq 1 ]]; then
  wg show wg0 | head -6
  echo ""
fi
for inst in "${INSTANCES[@]}"; do
  systemctl --no-pager status "tor-relay@${inst}" 2>&1 | head -4
  echo ""
done

# ── 5. MyFamily hint ─────────────────────────────────────────────────
NEEDS_FAMILY=0
for inst in "${INSTANCES[@]}"; do
  CONFFILE="/etc/tor/${inst}.torrc"
  if [[ -f "$CONFFILE" ]] && ! grep -q '^MyFamily' "$CONFFILE"; then
    NEEDS_FAMILY=1
    break
  fi
done
if [[ "$NEEDS_FAMILY" -eq 1 ]] && [[ "$NUM_RELAYS" -gt 1 ]]; then
  echo "NOTE: MyFamily is not configured. After relays have started, run:"
  echo "  sudo ./ubuntu_native_configure_myfamily.sh"
fi
