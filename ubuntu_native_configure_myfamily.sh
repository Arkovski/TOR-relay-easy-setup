#!/usr/bin/env bash
# Auto-configure MyFamily in all Tor relay torrc files.
# Waits for fingerprint files to appear, then sets MyFamily for each relay
# to include all OTHER relays' fingerprints.
# Run as root: sudo ./ubuntu_native_configure_myfamily.sh [--timeout N]
#   --timeout N   Seconds to wait for fingerprint files (default: 120)
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

TIMEOUT=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      [[ -n "${2:-}" ]] || { echo "ERROR: --timeout requires a number" >&2; exit 1; }
      TIMEOUT="$2"; shift 2
      ;;
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
  echo "ERROR: No tor-relay@tor*.service files found. Run ubuntu_native_first_run.sh first." >&2
  exit 1
fi

if [[ "$NUM_RELAYS" -lt 2 ]]; then
  echo "Only 1 relay detected — MyFamily is not needed for a single relay."
  exit 0
fi

echo "==> Detected $NUM_RELAYS relay instance(s): ${INSTANCES[*]}"

# ── 1. Wait for fingerprint files ────────────────────────────────────
echo "==> Waiting for fingerprint files (timeout: ${TIMEOUT}s)..."
ELAPSED=0
ALL_FOUND=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  ALL_FOUND=1
  for inst in "${INSTANCES[@]}"; do
    if [[ ! -f "/var/lib/tor-instances/${inst}/fingerprint" ]]; then
      ALL_FOUND=0
      break
    fi
  done
  if [[ $ALL_FOUND -eq 1 ]]; then break; fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  echo "    Waiting... (${ELAPSED}s/${TIMEOUT}s)"
done

if [[ $ALL_FOUND -eq 0 ]]; then
  echo "ERROR: Timed out waiting for fingerprint files." >&2
  echo "  Make sure all relays are running: sudo ./ubuntu_native_run.sh" >&2
  echo "  Missing fingerprints:" >&2
  for inst in "${INSTANCES[@]}"; do
    if [[ ! -f "/var/lib/tor-instances/${inst}/fingerprint" ]]; then
      echo "    /var/lib/tor-instances/${inst}/fingerprint" >&2
    fi
  done
  exit 1
fi

# ── 2. Parse fingerprints ────────────────────────────────────────────
declare -A FINGERPRINTS
for inst in "${INSTANCES[@]}"; do
  fp=$(awk '{print $2}' "/var/lib/tor-instances/${inst}/fingerprint")
  if [[ -z "$fp" ]]; then
    echo "ERROR: Could not parse fingerprint for $inst" >&2; exit 1
  fi
  FINGERPRINTS["$inst"]="$fp"
  echo "    $inst: $fp"
done

# ── 3. Update each torrc with MyFamily ───────────────────────────────
echo ""
echo "==> Configuring MyFamily in each torrc..."
for inst in "${INSTANCES[@]}"; do
  CONFFILE="/etc/tor/${inst}.torrc"
  if [[ ! -f "$CONFFILE" ]]; then
    echo "    WARNING: $CONFFILE not found, skipping $inst" >&2
    continue
  fi

  # Build MyFamily line: all OTHER relays' fingerprints
  FAMILY_PARTS=()
  for other in "${INSTANCES[@]}"; do
    if [[ "$other" != "$inst" ]]; then
      FAMILY_PARTS+=("\$${FINGERPRINTS[$other]}")
    fi
  done
  FAMILY_LINE="MyFamily $(IFS=,; echo "${FAMILY_PARTS[*]}")"

  # Replace existing MyFamily line (commented or not), or append
  if grep -q '^#\?MyFamily' "$CONFFILE"; then
    sed -i "s|^#\?MyFamily.*|${FAMILY_LINE}|" "$CONFFILE"
  else
    echo "$FAMILY_LINE" >> "$CONFFILE"
  fi
  echo "    $inst: $FAMILY_LINE"
done

# ── 4. Restart all relay services ────────────────────────────────────
echo ""
echo "==> Restarting relay services..."
for inst in "${INSTANCES[@]}"; do
  systemctl restart "tor-relay@${inst}"
  echo "    Restarted tor-relay@${inst}"
done

echo ""
echo "==> MyFamily configured for $NUM_RELAYS relays."
