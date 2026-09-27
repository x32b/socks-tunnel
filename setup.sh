#!/usr/bin/env bash
# Interactive setup for either side of the tunnel.
#
#   ./setup.sh          # asks which side: client or server
#   ./setup.sh client   # or:  ./setup.sh server
#
# Client (local machine): asks for the relay/ports/users, writes the answers
#   to config.local.env (gitignored) and runs setup-local.sh (keypair +
#   ~/.ssh/config block).
# Server (relay, run with sudo): asks for the tunnel user, the client's
#   public key and the source allow-list (+ hardening flags), then runs
#   setup-remote.sh. Entering a single client IP can automatically fetch the
#   full ISP/ASN prefix list for REMOTE_ALLOW_FROM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"
[[ -f "$SCRIPT_DIR/config.local.env" ]] && source "$SCRIPT_DIR/config.local.env"

ask() {
  # $1 prompt, $2 variable name, $3 default
  local _txt="$1" _def="$3" _ans
  read -r -p "$_txt [$_def]: " _ans || _ans="$_def"
  printf -v "$2" '%s' "${_ans:-$_def}"
}

valid_ip() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    (( o > 255 )) && return 1
  done
  return 0
}

fetch_asn() {
  # $1 IP -> echoes the AS number, or nothing on failure
  local ip="$1" asn
  asn="$(curl -s --max-time 15 "https://api.hackertarget.com/aslookup/?q=$ip" \
         | grep -oE '"[0-9]{2,7}"' | head -1 | tr -d '"')"
  if [[ -n "$asn" ]]; then echo "$asn"; return 0; fi
  asn="$(curl -s --max-time 15 "http://ip-api.com/json/$ip" \
         | grep -oE '"as":"AS[0-9]+' | grep -oE '[0-9]+$')"
  echo "$asn"
}

fetch_prefixes() {
  # $1 asn -> echoes comma-separated IPv4 prefixes announced by the ASN
  curl -s --max-time 25 "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS$1" \
    | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}' \
    | sort -u | tr '\n' ',' | sed 's/,$//'
}

ask_allow_list() {
  # Ask for REMOTE_ALLOW_FROM: auto-fetch from one client IP, paste, or none.
  local ip asn pfx ans
  read -r -p "Client public IP to auto-fetch its ISP prefixes (blank to skip): " ip
  if [[ -n "$ip" ]]; then
    if valid_ip "$ip"; then
      asn="$(fetch_asn "$ip")" || true
      if [[ -n "$asn" ]]; then
        echo "  ASN for $ip: AS$asn; fetching announced IPv4 prefixes..."
        pfx="$(fetch_prefixes "$asn" || true)"
        if [[ -n "$pfx" ]]; then
          n="${pfx//[^,]/}"; echo "  Got $(( ${#n} + 1 )) prefixes: ${pfx}"
          ask "  Use this list as REMOTE_ALLOW_FROM (y/n/e=edit)" keep "y"
          case "$keep" in
            y|Y|yes) REMOTE_ALLOW_FROM="$pfx"; return 0 ;;
            e|E|edit)
              read -r -p "  Paste the allow-list (comma-separated, blank to clear): " REMOTE_ALLOW_FROM
              if [[ -n "$REMOTE_ALLOW_FROM" ]] && [[ "$REMOTE_ALLOW_FROM" =~ [\"\'\ ] ]]; then
                echo "Error: REMOTE_ALLOW_FROM must not contain spaces or quotes." >&2
                exit 1
              fi
              return 0 ;;
          esac
        else
          echo "  WARN: no prefixes returned for AS$asn." >&2
        fi
      else
        echo "  WARN: could not determine ASN for $ip." >&2
      fi
    else
      echo "  WARN: '$ip' is not a valid IPv4 address." >&2
    fi
  fi
  read -r -p "Paste REMOTE_ALLOW_FROM manually (comma-separated, blank for none): " REMOTE_ALLOW_FROM
  if [[ -n "$REMOTE_ALLOW_FROM" ]] && [[ "$REMOTE_ALLOW_FROM" =~ [\"\'\ ] ]]; then
    echo "Error: REMOTE_ALLOW_FROM must not contain spaces or quotes." >&2
    exit 1
  fi
}

client_setup() {
  local CONF="$SCRIPT_DIR/config.local.env" SOCKS_LINE pb_dflt PB_ANS

  echo "== socks-tunnel CLIENT setup =="
  echo "Press Enter to accept a shown default. Ctrl-C to abort."
  echo

  ask "Relay server (tunnel exit) hostname or IP" REMOTE_HOST ""
  while [[ -z "$REMOTE_HOST" || "$REMOTE_HOST" == "CHANGE_ME" ]]; do
    echo "  Required."
    ask "Relay server hostname or IP" REMOTE_HOST ""
  done

  ask "Relay SSH port" REMOTE_PORT "$REMOTE_PORT"
  while ! [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] || (( REMOTE_PORT < 1 || REMOTE_PORT > 65535 )); do
    echo "  Must be a port number 1-65535."
    ask "Relay SSH port" REMOTE_PORT "$REMOTE_PORT"
  done

  ask "User with sudo on the relay (for the initial transfer)" REMOTE_USER ""
  while [[ -z "$REMOTE_USER" || "$REMOTE_USER" == "CHANGE_ME" ]]; do
    echo "  Required."
    ask "User with sudo on the relay" REMOTE_USER ""
  done

  ask "Dedicated tunnel user on the relay" TUNNEL_USER "$TUNNEL_USER"
  ask "Name of the ~/.ssh/config host block" SSHCONFIG_HOST "$SSHCONFIG_HOST"

  ask "Local SOCKS listen (host:port)" SOCKS_LINE "$LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT"
  if [[ "$SOCKS_LINE" == *:* ]]; then
    LOCAL_SOCKS_ADDR="${SOCKS_LINE%:*}"
    LOCAL_SOCKS_PORT="${SOCKS_LINE##*:}"
  else
    LOCAL_SOCKS_ADDR="$SOCKS_LINE"
  fi
  while ! [[ "$LOCAL_SOCKS_PORT" =~ ^[0-9]+$ ]] || (( LOCAL_SOCKS_PORT < 1 || LOCAL_SOCKS_PORT > 65535 )); do
    echo "  Must be a port number 1-65535."
    ask "Local SOCKS port" LOCAL_SOCKS_PORT "$LOCAL_SOCKS_PORT"
  done

  pb_dflt="n"; [[ "$PROXY_BRIDGE" == "1" ]] && pb_dflt="y"
  ask "Enable HTTP bridge for tools that ignore socks5 (y/n)" PB_ANS "$pb_dflt"
  [[ "$PB_ANS" =~ ^(y|Y|yes|1)$ ]] && PROXY_BRIDGE=1 || PROXY_BRIDGE=0

  ask "NO_PROXY domains (comma-separated, e.g. your LLM API)" PROXY_BYPASS "$PROXY_BYPASS"

  echo
  echo "Optional source allow-list (REMOTE_ALLOW_FROM):"
  echo "  Comma-separated CIDRs of THIS machine's public addresses that the"
  echo "  tunnel key may be used from. Applied on the relay."
  ask_allow_list

  cat > "$CONF" <<EOF
# Local overrides generated by setup.sh on $(date +%F).
# Your private settings - this file is gitignored, do not commit it.
# It is sourced AFTER config.env, so these values win over the defaults.
REMOTE_HOST=$REMOTE_HOST
REMOTE_PORT=$REMOTE_PORT
REMOTE_USER=$REMOTE_USER
TUNNEL_USER=$TUNNEL_USER
SSHCONFIG_HOST=$SSHCONFIG_HOST
LOCAL_SOCKS_ADDR=$LOCAL_SOCKS_ADDR
LOCAL_SOCKS_PORT=$LOCAL_SOCKS_PORT
PROXY_SOCKS5H=$PROXY_SOCKS5H
PROXY_BRIDGE=$PROXY_BRIDGE
PROXY_BYPASS=$PROXY_BYPASS
BRIDGE_PORT=$BRIDGE_PORT
REMOTE_ALLOW_FROM=$REMOTE_ALLOW_FROM
EOF
  echo
  echo "Wrote $CONF"
  echo

  echo "Generating the tunnel key and ~/.ssh/config block (setup-local.sh)..."
  "$SCRIPT_DIR/setup-local.sh"
}

server_setup() {
  local KEY_ARG y answer

  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Server setup needs root. Re-running under sudo..."
    exec sudo "$0" server
  fi

  echo "== socks-tunnel SERVER (relay) setup =="
  echo "Press Enter to accept a shown default. Ctrl-C to abort."
  echo

  ask "Dedicated tunnel user to create on this server" TUNNEL_USER "$TUNNEL_USER"

  while :; do
    read -r -p "Tunnel public key (path to .pub file, or paste the key): " KEY_ARG
    if [[ -f "$KEY_ARG" ]]; then
      KEY_ARG="$(cat "$KEY_ARG")"
    fi
    [[ "$KEY_ARG" =~ ^ssh-(ed25519|rsa|ecdsa|dss)(|-sk)?[[:space:]] ]] && break
    echo "  Invalid: expected a path to a .pub file or a key like 'ssh-ed25519 AAAA...'"
  done

  echo
  echo "Source allow-list for the tunnel key (REMOTE_ALLOW_FROM):"
  echo "  Enter one public IP of the client to fetch its ISP/ASN prefixes,"
  echo "  or paste the CIDR list yourself. Blank = key works from anywhere."
  ask_allow_list

  d_allow="n"; [[ "$SSH_ALLOW_USERS" == 1 ]] && d_allow="y"
  read -r -p "Restrict sshd to admin + tunnel user (SSH_ALLOW_USERS=1)? (y/n) [$d_allow]: " ans; [[ "${ans:-$d_allow}" =~ ^[yY1]?$ ]] && SSH_ALLOW_USERS=1 || SSH_ALLOW_USERS=0
  d_hard="n"; [[ "$SSH_HARDEN" == 1 ]] && d_hard="y"
  read -r -p "Apply global sshd hardening: no passwords, no root login (SSH_HARDEN=1)? (y/n) [$d_hard]: " ans; [[ "${ans:-$d_hard}" =~ ^[yY1]?$ ]] && SSH_HARDEN=1 || SSH_HARDEN=0
  d_f2b="n"; [[ "$INSTALL_FAIL2BAN" == 1 ]] && d_f2b="y"
  read -r -p "Install and enable fail2ban (INSTALL_FAIL2BAN=1)? (y/n) [$d_f2b]: " ans; [[ "${ans:-$d_f2b}" =~ ^[yY1]?$ ]] && INSTALL_FAIL2BAN=1 || INSTALL_FAIL2BAN=0
  d_ufw="n"; [[ "$ENABLE_UFW" == 1 ]] && d_ufw="y"
  read -r -p "Enable ufw with SSH only open (ENABLE_UFW=1)? (y/n) [$d_ufw]: " ans; [[ "${ans:-$d_ufw}" =~ ^[yY1]?$ ]] && ENABLE_UFW=1 || ENABLE_UFW=0

  echo
  echo "-- Applying on this server --"
  echo "  tunnel user:        $TUNNEL_USER"
  echo "  source allow-list:  ${REMOTE_ALLOW_FROM:-<any>}"
  echo "  SSH_ALLOW_USERS:    $SSH_ALLOW_USERS   SSH_HARDEN: $SSH_HARDEN"
  echo "  INSTALL_FAIL2BAN:   $INSTALL_FAIL2BAN  ENABLE_UFW: $ENABLE_UFW"
  read -r -p "Proceed? (y/N): " ans
  [[ "$ans" =~ ^[yY]$ ]] || { echo "Aborted."; exit 1; }

  export TUNNEL_USER REMOTE_ALLOW_FROM SSH_ALLOW_USERS SSH_HARDEN INSTALL_FAIL2BAN ENABLE_UFW
  "$SCRIPT_DIR/setup-remote.sh" "$KEY_ARG"
}

role="${1:-}"
while [[ -z "$role" ]]; do
  echo "socks-tunnel setup - which machine:"
  echo "  [c] Client (local machine): relay/ports, config.local.env, keypair"
  echo "  [s] Server (relay, sudo): tunnel user, client key, allow-list, hardening"
  read -r -p "Choose (c/s): " -e role
done

case "$role" in
  c|C|client|local) client_setup ;;
  s|S|server|relay|remote) server_setup ;;
  *) echo "Unknown role '$role'. Use: ./setup.sh [client|server]" >&2; exit 1 ;;
esac