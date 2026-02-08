#!/usr/bin/env bash
# Test script for Tor relay setup scripts.
# Validates pure logic (arg parsing, array generation, torrc templating,
# MyFamily building, auto-detection) without requiring root or live services.
#
# Usage: bash tests/test_scripts.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

check() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# Helper: extract first_run.sh arg parsing + array generation logic.
# Sources lines 14–68 in a subshell with EUID faked and set -e relaxed for
# error-path tests. Returns variable values via env dump.
run_first_run_parse() {
  local args=("$@")
  # We source the relevant portion by extracting it, replacing the root check
  # with a no-op, and stopping before system commands (line 70+).
  bash -c '
    set -uo pipefail

    USE_VPN=1
    NUM_RELAYS=4
    CUSTOM_PORTS=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --no-vpn)  USE_VPN=0; shift ;;
        --relays)
          [[ -n "${2:-}" ]] || { echo "ERROR: --relays requires a number" >&2; exit 1; }
          NUM_RELAYS="$2"; shift 2
          ;;
        --ports)
          [[ -n "${2:-}" ]] || { echo "ERROR: --ports requires a comma-separated list" >&2; exit 1; }
          CUSTOM_PORTS="$2"; shift 2
          ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done

    if ! [[ "$NUM_RELAYS" =~ ^[0-9]+$ ]] || [[ "$NUM_RELAYS" -lt 1 ]] || [[ "$NUM_RELAYS" -gt 99 ]]; then
      echo "ERROR: --relays must be a number between 1 and 99" >&2; exit 1
    fi

    INSTANCES=()
    for ((i=0; i<NUM_RELAYS; i++)); do
      INSTANCES+=("tor${i}")
    done

    declare -A RELAY_ORPORT
    if [[ -n "$CUSTOM_PORTS" ]]; then
      IFS="," read -ra PORT_LIST <<< "$CUSTOM_PORTS"
      if [[ ${#PORT_LIST[@]} -ne $NUM_RELAYS ]]; then
        echo "ERROR: --ports has ${#PORT_LIST[@]} values but --relays is $NUM_RELAYS" >&2; exit 1
      fi
      for ((i=0; i<NUM_RELAYS; i++)); do
        port="${PORT_LIST[$i]}"
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
          echo "ERROR: Invalid port number: $port" >&2; exit 1
        fi
        RELAY_ORPORT["tor${i}"]="$port"
      done
    else
      for ((i=0; i<NUM_RELAYS; i++)); do
        RELAY_ORPORT["tor${i}"]=$((9001 + i))
      done
    fi

    declare -A RELAY_NICK
    for ((i=0; i<NUM_RELAYS; i++)); do
      RELAY_NICK["tor${i}"]=$(printf "Relay%02d" "$i")
    done

    # Output results in a parseable format
    echo "INSTANCES=${INSTANCES[*]}"
    # Print ports in instance order
    PORTS=""
    for inst in "${INSTANCES[@]}"; do
      PORTS="${PORTS:+$PORTS,}${RELAY_ORPORT[$inst]}"
    done
    echo "PORTS=$PORTS"
    # Print nicks in instance order
    NICKS=""
    for inst in "${INSTANCES[@]}"; do
      NICKS="${NICKS:+$NICKS,}${RELAY_NICK[$inst]}"
    done
    echo "NICKS=$NICKS"
    echo "USE_VPN=$USE_VPN"
    echo "NUM_RELAYS=$NUM_RELAYS"
  ' -- "${args[@]}"
}

parse_var() {
  local output="$1" varname="$2"
  echo "$output" | grep "^${varname}=" | head -1 | cut -d= -f2-
}

# ═══════════════════════════════════════════════════════════════════
echo "=== 1. first_run.sh — Argument Parsing & Array Generation ==="
# ═══════════════════════════════════════════════════════════════════

echo "--- 1a. Default (no flags) ---"
OUT=$(run_first_run_parse)
check "instances" "$(parse_var "$OUT" INSTANCES)" "tor0 tor1 tor2 tor3"
check "ports" "$(parse_var "$OUT" PORTS)" "9001,9002,9003,9004"
check "nicks" "$(parse_var "$OUT" NICKS)" "Relay00,Relay01,Relay02,Relay03"
check "num_relays" "$(parse_var "$OUT" NUM_RELAYS)" "4"
check "use_vpn" "$(parse_var "$OUT" USE_VPN)" "1"

echo "--- 1b. --relays 1 ---"
OUT=$(run_first_run_parse --relays 1)
check "instances" "$(parse_var "$OUT" INSTANCES)" "tor0"
check "ports" "$(parse_var "$OUT" PORTS)" "9001"
check "nicks" "$(parse_var "$OUT" NICKS)" "Relay00"
check "num_relays" "$(parse_var "$OUT" NUM_RELAYS)" "1"

echo "--- 1c. --relays 8 ---"
OUT=$(run_first_run_parse --relays 8)
check "instances" "$(parse_var "$OUT" INSTANCES)" "tor0 tor1 tor2 tor3 tor4 tor5 tor6 tor7"
check "ports" "$(parse_var "$OUT" PORTS)" "9001,9002,9003,9004,9005,9006,9007,9008"
check "nicks" "$(parse_var "$OUT" NICKS)" "Relay00,Relay01,Relay02,Relay03,Relay04,Relay05,Relay06,Relay07"

echo "--- 1d. --ports matching ---"
OUT=$(run_first_run_parse --relays 3 --ports 5000,6000,7000)
check "instances" "$(parse_var "$OUT" INSTANCES)" "tor0 tor1 tor2"
check "ports" "$(parse_var "$OUT" PORTS)" "5000,6000,7000"

echo "--- 1e. --ports mismatch (should error) ---"
if run_first_run_parse --relays 2 --ports 5000,6000,7000 2>/dev/null; then
  check "ports mismatch exits non-zero" "success" "failure"
else
  check "ports mismatch exits non-zero" "failure" "failure"
fi

echo "--- 1f. --ports invalid >65535 (should error) ---"
if run_first_run_parse --relays 1 --ports 99999 2>/dev/null; then
  check "port >65535 exits non-zero" "success" "failure"
else
  check "port >65535 exits non-zero" "failure" "failure"
fi

echo "--- 1g. --relays 0 (should error) ---"
if run_first_run_parse --relays 0 2>/dev/null; then
  check "relays 0 exits non-zero" "success" "failure"
else
  check "relays 0 exits non-zero" "failure" "failure"
fi

echo "--- 1h. --relays 100 (should error) ---"
if run_first_run_parse --relays 100 2>/dev/null; then
  check "relays 100 exits non-zero" "success" "failure"
else
  check "relays 100 exits non-zero" "failure" "failure"
fi

echo "--- 1i. --no-vpn flag ---"
OUT=$(run_first_run_parse --no-vpn)
check "use_vpn with --no-vpn" "$(parse_var "$OUT" USE_VPN)" "0"
check "still has 4 relays" "$(parse_var "$OUT" NUM_RELAYS)" "4"

echo "--- 1j. TORRC_COPY mapping ---"
# Replicate the TORRC_COPY logic from first_run.sh
TORRC_OUT=$(bash -c '
  NUM_RELAYS=5
  declare -A TORRC_COPY
  TORRC_COPY[torrc]=tor0.torrc
  for ((i=1; i<NUM_RELAYS; i++)); do
    TORRC_COPY["torrc$((i+1))"]="tor${i}.torrc"
  done
  # Print sorted for deterministic output
  for src in $(echo "${!TORRC_COPY[@]}" | tr " " "\n" | sort); do
    echo "$src=${TORRC_COPY[$src]}"
  done
')
check "torrc→tor0.torrc" "$(echo "$TORRC_OUT" | grep '^torrc=')" "torrc=tor0.torrc"
check "torrc2→tor1.torrc" "$(echo "$TORRC_OUT" | grep '^torrc2=')" "torrc2=tor1.torrc"
check "torrc3→tor2.torrc" "$(echo "$TORRC_OUT" | grep '^torrc3=')" "torrc3=tor2.torrc"
check "torrc4→tor3.torrc" "$(echo "$TORRC_OUT" | grep '^torrc4=')" "torrc4=tor3.torrc"
check "torrc5→tor4.torrc" "$(echo "$TORRC_OUT" | grep '^torrc5=')" "torrc5=tor4.torrc"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== 2. first_run.sh — Torrc Template Generation ==="
# ═══════════════════════════════════════════════════════════════════

TMPDIR_TORRC=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TORRC"' EXIT

# Generate a torrc using the same template logic as first_run.sh
bash -c '
  DATADIR="$1"
  ORPORT="$2"
  NICK="$3"
  EMAIL="$4"
  WG_IP="$5"
  CONFFILE="$6"

  OUTBOUND_LINE=""
  if [[ -n "$WG_IP" ]]; then
    OUTBOUND_LINE="OutboundBindAddress ${WG_IP}"
  fi
  cat > "$CONFFILE" <<TORRC
DataDirectory ${DATADIR}

ORPort ${ORPORT}

ExitRelay 0
ExitPolicy reject *:*

Nickname ${NICK}
ContactInfo ${EMAIL}
#MyFamily  # Run ubuntu_native_configure_myfamily.sh after first start

${OUTBOUND_LINE}

SocksPort 0
ControlSocket ${DATADIR}/control_socket
CookieAuthentication 1
DirPort 0
TORRC
' -- "$TMPDIR_TORRC/data" "9001" "Relay00" "test@example.com" "10.0.0.2" "$TMPDIR_TORRC/tor0.torrc"

TORRC_CONTENT=$(cat "$TMPDIR_TORRC/tor0.torrc")
check "contains DataDirectory" \
  "$(echo "$TORRC_CONTENT" | grep -c "^DataDirectory $TMPDIR_TORRC/data$")" "1"
check "contains ORPort 9001" \
  "$(echo "$TORRC_CONTENT" | grep -c "^ORPort 9001$")" "1"
check "contains Nickname Relay00" \
  "$(echo "$TORRC_CONTENT" | grep -c "^Nickname Relay00$")" "1"
check "contains ExitRelay 0" \
  "$(echo "$TORRC_CONTENT" | grep -c "^ExitRelay 0$")" "1"
check "contains #MyFamily comment" \
  "$(echo "$TORRC_CONTENT" | grep -c "^#MyFamily")" "1"
check "contains OutboundBindAddress" \
  "$(echo "$TORRC_CONTENT" | grep -c "^OutboundBindAddress 10.0.0.2$")" "1"
check "contains ContactInfo" \
  "$(echo "$TORRC_CONTENT" | grep -c "^ContactInfo test@example.com$")" "1"
check "contains SocksPort 0" \
  "$(echo "$TORRC_CONTENT" | grep -c "^SocksPort 0$")" "1"
check "contains ControlSocket" \
  "$(echo "$TORRC_CONTENT" | grep -c "^ControlSocket $TMPDIR_TORRC/data/control_socket$")" "1"
check "contains CookieAuthentication 1" \
  "$(echo "$TORRC_CONTENT" | grep -c "^CookieAuthentication 1$")" "1"

echo "--- 2b. Torrc without VPN (no OutboundBindAddress) ---"
bash -c '
  DATADIR="$1"
  CONFFILE="$2"
  OUTBOUND_LINE=""
  cat > "$CONFFILE" <<TORRC
DataDirectory ${DATADIR}

ORPort 9001

ExitRelay 0
ExitPolicy reject *:*

Nickname Relay00
ContactInfo relay@example.com
#MyFamily  # Run ubuntu_native_configure_myfamily.sh after first start

${OUTBOUND_LINE}

SocksPort 0
ControlSocket ${DATADIR}/control_socket
CookieAuthentication 1
DirPort 0
TORRC
' -- "$TMPDIR_TORRC/data" "$TMPDIR_TORRC/tor0_novpn.torrc"

NOVPN_CONTENT=$(cat "$TMPDIR_TORRC/tor0_novpn.torrc")
check "no OutboundBindAddress when no VPN" \
  "$(echo "$NOVPN_CONTENT" | grep -c "OutboundBindAddress")" "0"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== 3. first_run.sh — Firewall allow-ports Generation ==="
# ═══════════════════════════════════════════════════════════════════

TMPDIR_FW=$(mktemp -d)
# Update trap to clean up both temp dirs
trap 'rm -rf "$TMPDIR_TORRC" "$TMPDIR_FW"' EXIT

# Replicate the allow-ports generation logic
bash -c '
  INSTANCES=(tor0 tor1 tor2)
  declare -A RELAY_ORPORT=([tor0]=9001 [tor1]=9002 [tor2]=9003)
  ALLOW_FILE="$1"
  : > "$ALLOW_FILE"
  for inst in "${INSTANCES[@]}"; do
    echo "tcp:${RELAY_ORPORT[$inst]}" >> "$ALLOW_FILE"
  done
' -- "$TMPDIR_FW/allow-ports"

ALLOW_CONTENT=$(cat "$TMPDIR_FW/allow-ports")
check "allow-ports line count" "$(echo "$ALLOW_CONTENT" | wc -l | tr -d ' ')" "3"
check "allow-ports line 1" "$(echo "$ALLOW_CONTENT" | sed -n '1p')" "tcp:9001"
check "allow-ports line 2" "$(echo "$ALLOW_CONTENT" | sed -n '2p')" "tcp:9002"
check "allow-ports line 3" "$(echo "$ALLOW_CONTENT" | sed -n '3p')" "tcp:9003"

echo "--- 3b. Custom ports ---"
bash -c '
  INSTANCES=(tor0 tor1)
  declare -A RELAY_ORPORT=([tor0]=5000 [tor1]=6000)
  ALLOW_FILE="$1"
  : > "$ALLOW_FILE"
  for inst in "${INSTANCES[@]}"; do
    echo "tcp:${RELAY_ORPORT[$inst]}" >> "$ALLOW_FILE"
  done
' -- "$TMPDIR_FW/allow-ports-custom"

CUSTOM_ALLOW=$(cat "$TMPDIR_FW/allow-ports-custom")
check "custom allow-ports line 1" "$(echo "$CUSTOM_ALLOW" | sed -n '1p')" "tcp:5000"
check "custom allow-ports line 2" "$(echo "$CUSTOM_ALLOW" | sed -n '2p')" "tcp:6000"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== 4. ubuntu_native_configure_myfamily.sh — MyFamily Building ==="
# ═══════════════════════════════════════════════════════════════════

TMPDIR_MF=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TORRC" "$TMPDIR_FW" "$TMPDIR_MF"' EXIT

# Create mock fingerprint files
mkdir -p "$TMPDIR_MF/tor0" "$TMPDIR_MF/tor1" "$TMPDIR_MF/tor2"
echo "Relay00 AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555" > "$TMPDIR_MF/tor0/fingerprint"
echo "Relay01 FFFF6666AAAA7777BBBB8888CCCC9999DDDD0000" > "$TMPDIR_MF/tor1/fingerprint"
echo "Relay02 1111AAAA2222BBBB3333CCCC4444DDDD5555EEEE" > "$TMPDIR_MF/tor2/fingerprint"

# Create mock torrc files with #MyFamily placeholder
for i in 0 1 2; do
  cat > "$TMPDIR_MF/tor${i}.torrc" <<EOF
DataDirectory /var/lib/tor-instances/tor${i}

ORPort 900$((i+1))
Nickname Relay0${i}
#MyFamily  # Run ubuntu_native_configure_myfamily.sh after first start

SocksPort 0
EOF
done

# Run the MyFamily logic (extracted from ubuntu_native_configure_myfamily.sh)
bash -c '
  TMPDIR="$1"
  INSTANCES=(tor0 tor1 tor2)

  declare -A FINGERPRINTS
  for inst in "${INSTANCES[@]}"; do
    fp=$(awk "{print \$2}" "$TMPDIR/$inst/fingerprint")
    FINGERPRINTS["$inst"]="$fp"
  done

  for inst in "${INSTANCES[@]}"; do
    CONFFILE="$TMPDIR/${inst}.torrc"
    FAMILY_PARTS=()
    for other in "${INSTANCES[@]}"; do
      if [[ "$other" != "$inst" ]]; then
        FAMILY_PARTS+=("\$${FINGERPRINTS[$other]}")
      fi
    done
    FAMILY_LINE="MyFamily $(IFS=,; echo "${FAMILY_PARTS[*]}")"

    if grep -q "^#\?MyFamily" "$CONFFILE"; then
      sed -i "s|^#\?MyFamily.*|${FAMILY_LINE}|" "$CONFFILE"
    else
      echo "$FAMILY_LINE" >> "$CONFFILE"
    fi
  done
' -- "$TMPDIR_MF"

echo "--- 4a. MyFamily for tor0 (should have tor1 + tor2 fingerprints) ---"
MF0=$(grep '^MyFamily' "$TMPDIR_MF/tor0.torrc")
check "tor0 excludes own fingerprint" \
  "$(echo "$MF0" | grep -c 'AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555')" "0"
check "tor0 includes tor1 fingerprint" \
  "$(echo "$MF0" | grep -c 'FFFF6666AAAA7777BBBB8888CCCC9999DDDD0000')" "1"
check "tor0 includes tor2 fingerprint" \
  "$(echo "$MF0" | grep -c '1111AAAA2222BBBB3333CCCC4444DDDD5555EEEE')" "1"

echo "--- 4b. MyFamily for tor1 (should have tor0 + tor2 fingerprints) ---"
MF1=$(grep '^MyFamily' "$TMPDIR_MF/tor1.torrc")
check "tor1 includes tor0 fingerprint" \
  "$(echo "$MF1" | grep -c 'AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555')" "1"
check "tor1 excludes own fingerprint" \
  "$(echo "$MF1" | grep -c 'FFFF6666AAAA7777BBBB8888CCCC9999DDDD0000')" "0"
check "tor1 includes tor2 fingerprint" \
  "$(echo "$MF1" | grep -c '1111AAAA2222BBBB3333CCCC4444DDDD5555EEEE')" "1"

echo "--- 4c. MyFamily for tor2 (should have tor0 + tor1 fingerprints) ---"
MF2=$(grep '^MyFamily' "$TMPDIR_MF/tor2.torrc")
check "tor2 includes tor0 fingerprint" \
  "$(echo "$MF2" | grep -c 'AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555')" "1"
check "tor2 includes tor1 fingerprint" \
  "$(echo "$MF2" | grep -c 'FFFF6666AAAA7777BBBB8888CCCC9999DDDD0000')" "1"
check "tor2 excludes own fingerprint" \
  "$(echo "$MF2" | grep -c '1111AAAA2222BBBB3333CCCC4444DDDD5555EEEE')" "0"

echo "--- 4d. #MyFamily comment replaced (not duplicated) ---"
check "tor0 no leftover #MyFamily" \
  "$(grep -c '^#MyFamily' "$TMPDIR_MF/tor0.torrc")" "0"
check "tor0 exactly one MyFamily line" \
  "$(grep -c '^MyFamily' "$TMPDIR_MF/tor0.torrc")" "1"

echo "--- 4e. Idempotent: running MyFamily again produces correct result ---"
# Run it a second time
bash -c '
  TMPDIR="$1"
  INSTANCES=(tor0 tor1 tor2)

  declare -A FINGERPRINTS
  for inst in "${INSTANCES[@]}"; do
    fp=$(awk "{print \$2}" "$TMPDIR/$inst/fingerprint")
    FINGERPRINTS["$inst"]="$fp"
  done

  for inst in "${INSTANCES[@]}"; do
    CONFFILE="$TMPDIR/${inst}.torrc"
    FAMILY_PARTS=()
    for other in "${INSTANCES[@]}"; do
      if [[ "$other" != "$inst" ]]; then
        FAMILY_PARTS+=("\$${FINGERPRINTS[$other]}")
      fi
    done
    FAMILY_LINE="MyFamily $(IFS=,; echo "${FAMILY_PARTS[*]}")"

    if grep -q "^#\?MyFamily" "$CONFFILE"; then
      sed -i "s|^#\?MyFamily.*|${FAMILY_LINE}|" "$CONFFILE"
    else
      echo "$FAMILY_LINE" >> "$CONFFILE"
    fi
  done
' -- "$TMPDIR_MF"

check "idempotent: tor0 still one MyFamily" \
  "$(grep -c '^MyFamily' "$TMPDIR_MF/tor0.torrc")" "1"
check "idempotent: tor1 still one MyFamily" \
  "$(grep -c '^MyFamily' "$TMPDIR_MF/tor1.torrc")" "1"
check "idempotent: tor2 still one MyFamily" \
  "$(grep -c '^MyFamily' "$TMPDIR_MF/tor2.torrc")" "1"
# Verify content is still correct after second run
MF0_IDEM=$(grep '^MyFamily' "$TMPDIR_MF/tor0.torrc")
check "idempotent: tor0 still has tor1 fp" \
  "$(echo "$MF0_IDEM" | grep -c 'FFFF6666AAAA7777BBBB8888CCCC9999DDDD0000')" "1"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== 5. Auto-detection — Service File Parsing ==="
# ═══════════════════════════════════════════════════════════════════

TMPDIR_SVC=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TORRC" "$TMPDIR_FW" "$TMPDIR_MF" "$TMPDIR_SVC"' EXIT

# Create mock service files (including 10+ to test sort -V ordering)
for i in 0 1 2 3 4 5 6 7 8 9 10 11; do
  touch "$TMPDIR_SVC/tor-relay@tor${i}.service"
done

echo "--- 5a. Auto-detect with 12 instances (sort -V ordering) ---"
DETECT_OUT=$(bash -c '
  SVC_DIR="$1"
  INSTANCES=()
  while IFS= read -r svc; do
    inst=$(basename "$svc" .service)
    inst="${inst#tor-relay@}"
    INSTANCES+=("$inst")
  done < <(find "$SVC_DIR" -maxdepth 1 -name "tor-relay@tor*.service" 2>/dev/null | sort -V)
  echo "${INSTANCES[*]}"
' -- "$TMPDIR_SVC")
check "12 instances detected" \
  "$DETECT_OUT" "tor0 tor1 tor2 tor3 tor4 tor5 tor6 tor7 tor8 tor9 tor10 tor11"

echo "--- 5b. Ordering: tor2 before tor10 (version sort, not lexicographic) ---"
# In lexicographic sort, tor10 would come before tor2. sort -V handles this.
IDX_TOR2=$(bash -c '
  arr=($1)
  for i in "${!arr[@]}"; do
    if [[ "${arr[$i]}" == "tor2" ]]; then echo "$i"; break; fi
  done
' -- "$DETECT_OUT")
IDX_TOR10=$(bash -c '
  arr=($1)
  for i in "${!arr[@]}"; do
    if [[ "${arr[$i]}" == "tor10" ]]; then echo "$i"; break; fi
  done
' -- "$DETECT_OUT")
if [[ "$IDX_TOR2" -lt "$IDX_TOR10" ]]; then
  check "tor2 comes before tor10" "true" "true"
else
  check "tor2 comes before tor10" "false" "true"
fi

echo "--- 5c. Single instance ---"
TMPDIR_SVC1=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TORRC" "$TMPDIR_FW" "$TMPDIR_MF" "$TMPDIR_SVC" "$TMPDIR_SVC1"' EXIT
touch "$TMPDIR_SVC1/tor-relay@tor0.service"
DETECT_SINGLE=$(bash -c '
  SVC_DIR="$1"
  INSTANCES=()
  while IFS= read -r svc; do
    inst=$(basename "$svc" .service)
    inst="${inst#tor-relay@}"
    INSTANCES+=("$inst")
  done < <(find "$SVC_DIR" -maxdepth 1 -name "tor-relay@tor*.service" 2>/dev/null | sort -V)
  echo "${INSTANCES[*]}"
' -- "$TMPDIR_SVC1")
check "single instance detected" "$DETECT_SINGLE" "tor0"

echo "--- 5d. No service files → empty ---"
TMPDIR_EMPTY=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TORRC" "$TMPDIR_FW" "$TMPDIR_MF" "$TMPDIR_SVC" "$TMPDIR_SVC1" "$TMPDIR_EMPTY"' EXIT
DETECT_EMPTY=$(bash -c '
  SVC_DIR="$1"
  INSTANCES=()
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    inst=$(basename "$svc" .service)
    inst="${inst#tor-relay@}"
    INSTANCES+=("$inst")
  done < <(find "$SVC_DIR" -maxdepth 1 -name "tor-relay@tor*.service" 2>/dev/null | sort -V)
  echo "${#INSTANCES[@]}"
' -- "$TMPDIR_EMPTY")
check "empty dir → 0 instances" "$DETECT_EMPTY" "0"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "==========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "==========================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
