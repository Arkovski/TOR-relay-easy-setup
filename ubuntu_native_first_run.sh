#!/usr/bin/env bash
# One-time setup: install packages and configure Tor non-exit relays
# over WireGuard VPN on a native Ubuntu Server.
# If share/ is present next to this script, configs and identity keys
# are copied automatically.
# Run as root: sudo ./ubuntu_native_first_run.sh [--no-vpn] [--relays N] [--ports P1,P2,...]
#   --no-vpn        Skip WireGuard and firewall setup (direct port forwarding)
#   --relays N      Number of relay instances (default: 4)
#   --ports P1,...   Comma-separated ORPorts (must match --relays count)
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

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

# Validate NUM_RELAYS
if ! [[ "$NUM_RELAYS" =~ ^[0-9]+$ ]] || [[ "$NUM_RELAYS" -lt 1 ]] || [[ "$NUM_RELAYS" -gt 99 ]]; then
  echo "ERROR: --relays must be a number between 1 and 99" >&2; exit 1
fi

# Build INSTANCES array: tor0, tor1, ..., tor{N-1}
INSTANCES=()
for ((i=0; i<NUM_RELAYS; i++)); do
  INSTANCES+=("tor${i}")
done

# Build RELAY_ORPORT: from --ports or sequential 9001..9000+N
declare -A RELAY_ORPORT
if [[ -n "$CUSTOM_PORTS" ]]; then
  IFS=',' read -ra PORT_LIST <<< "$CUSTOM_PORTS"
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

# Build RELAY_NICK: Relay00, Relay01, ..., Relay{N-1}
declare -A RELAY_NICK
for ((i=0; i<NUM_RELAYS; i++)); do
  RELAY_NICK["tor${i}"]=$(printf "Relay%02d" "$i")
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARE="$SCRIPT_DIR/share"

# ── 1. Copy configs from share/ (if present) ────────────────────────
if [[ -d "$SHARE" ]] && [[ -n "$(ls -A "$SHARE" 2>/dev/null)" ]]; then
  echo "==> Found share/, copying configs..."

  # WireGuard
  if [[ -f "$SHARE/wg0.conf" ]]; then
    mkdir -p /etc/wireguard
    cp "$SHARE/wg0.conf" /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    echo "    wg0.conf → /etc/wireguard/"
  fi

  # Tor configs: torrc→tor0, torrc2→tor1, torrc3→tor2, ..., torrc{N}→tor{N-1}
  declare -A TORRC_COPY
  TORRC_COPY[torrc]=tor0.torrc
  for ((i=1; i<NUM_RELAYS; i++)); do
    TORRC_COPY["torrc$((i+1))"]="tor${i}.torrc"
  done

  mkdir -p /etc/tor
  for src in "${!TORRC_COPY[@]}"; do
    if [[ -f "$SHARE/$src" ]]; then
      cp "$SHARE/$src" "/etc/tor/${TORRC_COPY[$src]}"
      echo "    $src → /etc/tor/${TORRC_COPY[$src]}"
    fi
  done

  # Identity keys
  KEYS_BACKUP=$(find "$SHARE" -maxdepth 1 -type d -name 'tor-identities-*' 2>/dev/null | head -1)
  if [[ -n "${KEYS_BACKUP:-}" ]]; then
    # tor0 keys (backup stores them under /var/lib/tor/keys)
    if [[ -d "$KEYS_BACKUP/var/lib/tor/keys" ]]; then
      mkdir -p /var/lib/tor-instances/tor0/keys
      cp "$KEYS_BACKUP/var/lib/tor/keys"/* /var/lib/tor-instances/tor0/keys/
      echo "    tor0 identity keys → /var/lib/tor-instances/tor0/keys/"
    fi
    # tor1..tor{N-1} keys
    for ((i=1; i<NUM_RELAYS; i++)); do
      inst="tor${i}"
      if [[ -d "$KEYS_BACKUP/var/lib/tor-instances/$inst/keys" ]]; then
        mkdir -p "/var/lib/tor-instances/$inst/keys"
        cp "$KEYS_BACKUP/var/lib/tor-instances/$inst/keys"/* "/var/lib/tor-instances/$inst/keys/"
        echo "    $inst identity keys → /var/lib/tor-instances/$inst/keys/"
      fi
    done
  fi
else
  echo "==> No share/ directory found, skipping config copy."
fi

# ── 2. Add official Tor Project repository ─────────────────────────
# Uses the Tor Project's own apt repo for the latest stable version
# instead of the older Ubuntu-packaged build.
# Signing key fingerprint: A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89
# If this key is rotated, update TOR_KEYRING_ID below.
# Codename is jammy (Tor Project supports LTS bases first).
echo "==> Adding official Tor Project repository..."
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg wget

TOR_KEYRING_ID="A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89"
wget -q -P /tmp "https://deb.torproject.org/torproject.org/${TOR_KEYRING_ID}.asc"
gpg --batch --yes --dearmor "/tmp/${TOR_KEYRING_ID}.asc"
mv "/tmp/${TOR_KEYRING_ID}.asc.gpg" /usr/share/keyrings/tor-archive-keyring.gpg
rm -f "/tmp/${TOR_KEYRING_ID}.asc"

echo "deb [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://deb.torproject.org/torproject.org jammy main" \
  | tee /etc/apt/sources.list.d/tor.list > /dev/null

# ── 3. Install packages ─────────────────────────────────────────────
echo "==> Installing packages..."
apt-get update
if [[ "$USE_VPN" -eq 1 ]]; then
  apt-get install -y tor deb.torproject.org-keyring nftables wireguard-tools
else
  apt-get install -y tor deb.torproject.org-keyring nftables
fi

# Stop and disable the default tor service (we use our own units)
systemctl stop tor 2>/dev/null || true
systemctl disable tor 2>/dev/null || true

# ── 4. WireGuard ────────────────────────────────────────────────────
WG_IP=""
if [[ "$USE_VPN" -eq 1 ]]; then
  if [[ ! -f /etc/wireguard/wg0.conf ]]; then
    echo "ERROR: /etc/wireguard/wg0.conf not found."
    echo "  Place it manually: sudo cp /path/to/wg0.conf /etc/wireguard/"
    exit 1
  fi
  chmod 600 /etc/wireguard/wg0.conf

  # Extract WireGuard tunnel IPv4 for Tor OutboundBindAddress
  WG_IP=$(grep -oP 'Address\s*=\s*\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' /etc/wireguard/wg0.conf)
  echo "    WireGuard tunnel IP: $WG_IP"
else
  echo "==> Skipping WireGuard setup (--no-vpn)"
fi

# ── 5. VPN kill-switch firewall ─────────────────────────────────────
if [[ "$USE_VPN" -eq 1 ]]; then
mkdir -p /etc/vpn-firewall

cat > /usr/local/sbin/vpn-firewall-rebuild <<'FWEOF'
#!/usr/bin/env bash
set -euo pipefail

WGCONF=${WGCONF:-/etc/wireguard/wg0.conf}
SSH_PORT=${SSH_PORT:-22}
ALLOW_SSH_OUTSIDE_WG=${ALLOW_SSH_OUTSIDE_WG:-0}
ALLOW_DHCP=${ALLOW_DHCP:-0}

[ -r /etc/vpn-firewall/env ] && . /etc/vpn-firewall/env || true

UPLINK_IF=""
if [ "$ALLOW_DHCP" = "1" ]; then
  UPLINK_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [ "${UPLINK_IF:-}" = "wg0" ] && UPLINK_IF=""
fi

[ -r "$WGCONF" ] || { echo "ERR: $WGCONF not readable" >&2; exit 1; }
EPHOST=$(awk -F' *= *' '/^Endpoint[[:space:]]*=/ {print $2; exit}' "$WGCONF" | cut -d: -f1)
EPPORT=$(awk -F' *= *' '/^Endpoint[[:space:]]*=/ {print $2; exit}' "$WGCONF" | cut -d: -f2)
[ -n "${EPHOST:-}" ] && [ -n "${EPPORT:-}" ] || { echo "ERR: Endpoint missing in $WGCONF" >&2; exit 1; }

EP4S=$(getent ahostsv4 "$EPHOST" | awk '{print $1}' | sort -u || true)
EP6S=$(getent ahostsv6 "$EPHOST" | awk '{print $1}' | sort -u || true)

EP4_RULES=""; for ip in $EP4S; do EP4_RULES="${EP4_RULES}    ip daddr ${ip} udp dport ${EPPORT} accept
"; done
EP6_RULES=""; for ip in $EP6S; do EP6_RULES="${EP6_RULES}    ip6 daddr ${ip} udp dport ${EPPORT} accept
"; done

if [ "$ALLOW_SSH_OUTSIDE_WG" = "1" ]; then
  SSH_RULE='    tcp dport '"$SSH_PORT"' accept'
else
  SSH_RULE='    iifname "wg0" tcp dport '"$SSH_PORT"' accept'
fi

DHCP_RULE=""
if [ "$ALLOW_DHCP" = "1" ] && [ -n "${UPLINK_IF:-}" ]; then
  DHCP_RULE='    oifname "'"$UPLINK_IF"'" ip saddr 0.0.0.0 udp sport 68 udp dport 67 accept'
fi

cat >/etc/nftables.conf <<NFT
flush ruleset
table inet filter {
  set vpn_inbound_tcp { type inet_service; }
  set vpn_inbound_udp { type inet_service; }

  chain input {
    type filter hook input priority 0;
    policy drop;

    iifname "lo" accept
    ct state established,related accept
${SSH_RULE}

    iifname "wg0" tcp dport @vpn_inbound_tcp accept
    iifname "wg0" udp dport @vpn_inbound_udp accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy drop;

    oifname "lo" accept
    ct state established,related accept
${DHCP_RULE}

${EP4_RULES}${EP6_RULES}    oifname "wg0" accept
  }
}
NFT

nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf

ALLOW=/etc/vpn-firewall/allow-ports
if [ -f "$ALLOW" ]; then
  while IFS= read -r line; do
    case "$line" in
      tcp:*) nft add element inet filter vpn_inbound_tcp { ${line#tcp:} } || true ;;
      udp:*) nft add element inet filter vpn_inbound_udp { ${line#udp:} } || true ;;
      *) : ;;
    esac
  done < <(grep -E '^(tcp|udp):[0-9]+$' "$ALLOW" | sort -u || true)
fi
FWEOF
chmod +x /usr/local/sbin/vpn-firewall-rebuild

# Allow all Tor ORPorts inbound through the VPN firewall
: > /etc/vpn-firewall/allow-ports
for inst in "${INSTANCES[@]}"; do
  echo "tcp:${RELAY_ORPORT[$inst]}" >> /etc/vpn-firewall/allow-ports
done

# Allow SSH from outside the WG tunnel (so you don't get locked out)
cat > /etc/vpn-firewall/env <<'EOF'
ALLOW_SSH_OUTSIDE_WG=1
EOF
else
  echo "==> Skipping firewall setup (--no-vpn)"
fi

# ── 6. Tor relay instances ──────────────────────────────────────────
# ── Relay configuration ───────────────────────────────────────────
# Customize these for your setup:
#   RELAY_ORPORT  — ports forwarded by your VPN provider or router
#   RELAY_NICK    — unique nickname for each relay
#   CONTACT_EMAIL — your contact email for the Tor directory
# MyFamily is left empty on first run — run ubuntu_native_configure_myfamily.sh
# after Tor generates fingerprints to set it automatically.
CONTACT_EMAIL="${CONTACT_EMAIL:-relay@example.com}"

for inst in "${INSTANCES[@]}"; do
  DATADIR="/var/lib/tor-instances/${inst}"
  CONFFILE="/etc/tor/${inst}.torrc"

  mkdir -p "$DATADIR"
  chown debian-tor:debian-tor "$DATADIR"
  chmod 700 "$DATADIR"

  if [[ -f "$CONFFILE" ]]; then
    echo "    $CONFFILE already exists (copied from share/), keeping it."
    # Ensure DataDirectory is set (the original torrc for tor0 lacks it)
    if ! grep -q '^DataDirectory' "$CONFFILE"; then
      sed -i "1i DataDirectory ${DATADIR}" "$CONFFILE"
      echo "    Added DataDirectory to $CONFFILE"
    fi
  else
    OUTBOUND_LINE=""
    if [[ -n "$WG_IP" ]]; then
      OUTBOUND_LINE="OutboundBindAddress ${WG_IP}"
    fi
    cat > "$CONFFILE" <<TORRC
DataDirectory ${DATADIR}

ORPort ${RELAY_ORPORT[$inst]}

ExitRelay 0
ExitPolicy reject *:*

Nickname ${RELAY_NICK[$inst]}
ContactInfo ${CONTACT_EMAIL}
#MyFamily  # Run ubuntu_native_configure_myfamily.sh after first start

${OUTBOUND_LINE}

SocksPort 0
ControlSocket ${DATADIR}/control_socket
CookieAuthentication 1
DirPort 0
TORRC
  fi
  chown debian-tor:debian-tor "$CONFFILE"

  # systemd service unit
  if [[ "$USE_VPN" -eq 1 ]]; then
    AFTER_LINE="After=network-online.target wg-quick@wg0.service"
  else
    AFTER_LINE="After=network-online.target"
  fi
  cat > "/etc/systemd/system/tor-relay@${inst}.service" <<UNIT
[Unit]
Description=Tor Relay – ${inst}
${AFTER_LINE}
Wants=network-online.target

[Service]
Type=simple
User=debian-tor
ExecStart=/usr/bin/tor -f /etc/tor/${inst}.torrc
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
done

systemctl daemon-reload
for inst in "${INSTANCES[@]}"; do
  systemctl enable "tor-relay@${inst}"
done
if [[ "$USE_VPN" -eq 1 ]]; then
  systemctl enable wg-quick@wg0
fi

# ── 7. Fix ownership on identity keys (if copied earlier) ───────────
for inst in "${INSTANCES[@]}"; do
  if [[ -d "/var/lib/tor-instances/${inst}/keys" ]]; then
    chown -R debian-tor:debian-tor "/var/lib/tor-instances/${inst}"
    echo "    Fixed ownership on /var/lib/tor-instances/${inst}/keys"
  fi
done

echo ""
echo "==> Setup complete. $NUM_RELAYS Tor relay instance(s) configured."
echo ""
echo "Next steps:"
echo "  1. Start everything:  sudo ./ubuntu_native_run.sh"
echo "  2. After Tor starts, auto-configure MyFamily:"
echo "     sudo ./ubuntu_native_configure_myfamily.sh"
echo "  3. Update ContactInfo in each torrc with your real email."
echo "  4. Verify fingerprints:"
for inst in "${INSTANCES[@]}"; do
  echo "     sudo cat /var/lib/tor-instances/${inst}/fingerprint"
done
