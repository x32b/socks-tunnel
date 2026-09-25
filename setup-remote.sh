#!/usr/bin/env bash
# Setup for the REMOTE (relay) server.
# Runs directly ON the remote server, as root:
#
#   sudo ./setup-remote.sh "$(cat ~/tunnel.pub)"     # key passed inline
#   sudo ./setup-remote.sh ~/tunnel.pub               # key passed as a file
#
# The public key must be brought to the server manually (scp / web console).
#
# What it does:
#   - creates a dedicated user (<TUNNEL_USER>, default "tunnel") with a
#     nologin shell;
#   - installs the key restricted to port forwarding only, and - when
#     REMOTE_ALLOW_FROM is set - further restricted with from=<CIDR list>;
#   - writes an sshd drop-in (sshd_config.d) enabling forwarding for the
#     tunnel user only from the allowed sources, plus optional hardening.
#     The base /etc/ssh/sshd_config is NOT modified when the distro uses
#     sshd_config.d includes.
set -euo pipefail

# ===== Settings (edit here or override via env vars) =====
TUNNEL_USER="${TUNNEL_USER:-tunnel}"        # dedicated user restricted to tunnelling
SSH_PORT="${SSH_PORT:-22}"
REMOTE_ALLOW_FROM="${REMOTE_ALLOW_FROM:-}"  # CIDR/IP allow-list for the tunnel key (from=)
SSH_ALLOW_USERS="${SSH_ALLOW_USERS:-0}"     # 1 = write explicit AllowUsers <admin> <tunnel>
SSH_HARDEN="${SSH_HARDEN:-1}"               # 1 = ensure sshd hardening via drop-in
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-0}"   # 1 = install and enable fail2ban
ENABLE_UFW="${ENABLE_UFW:-0}"               # 1 = enable ufw (SSH only)
UFW_ALLOW_FROM="${UFW_ALLOW_FROM:-$REMOTE_ALLOW_FROM}"  # ufw SSH source allow-list; empty = all
# ================================================================

# Whoever runs the script keeps working access after hardening
ADMIN_USER="$(id -un)"
if [[ ${SUDO_USER:-unset} != "unset" && -n "$SUDO_USER" ]]; then
  ADMIN_USER="$SUDO_USER"
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root:   sudo $0 '<public key>'"
  exit 1
fi

USAGE="Usage: sudo $0 '<ssh-ed25519 AA... comment>' | sudo $0 /path/to/key.pub"
if [[ $# -lt 1 ]]; then
  echo "$USAGE" >&2
  exit 1
fi
if [[ "$1" == ssh-* ]]; then
  PUBKEY="$1"
elif [[ -f "$1" ]]; then
  PUBKEY="$(tr -d '\r\n' < "$1")"
else
  echo "$USAGE" >&2
  echo "The argument is neither an inline key nor an existing file: $1" >&2
  exit 1
fi
case "$PUBKEY" in
  ssh-*) ;;
  *) echo "Error: the key must start with 'ssh-...'"; exit 1 ;;
esac

# Validate the allow-list: no whitespace or quotes (must be a,b,c CIDR list)
if [[ -n "$REMOTE_ALLOW_FROM" ]]; then
  if [[ "$REMOTE_ALLOW_FROM" =~ [\"\'\ ] ]]; then
    echo "Error: REMOTE_ALLOW_FROM must be a comma-separated list (no spaces/quotes): $REMOTE_ALLOW_FROM" >&2
    exit 1
  fi
  echo "Source allow-list for the tunnel key: $REMOTE_ALLOW_FROM"
fi

if [[ "$SSH_ALLOW_USERS" == "1" ]]; then
  echo "Will restrict sshd to users: $ADMIN_USER $TUNNEL_USER"
fi

NOLOGIN="$(command -v nologin || echo /usr/sbin/nologin)"

echo "[1/4] Tunnel user '$TUNNEL_USER'..."
if id "$TUNNEL_USER" >/dev/null 2>&1; then
  echo "    already exists"
else
  useradd -m -s "$NOLOGIN" "$TUNNEL_USER"
  echo "    created"
fi
usermod -s "$NOLOGIN" "$TUNNEL_USER"

echo "[2/4] Installing restricted public key..."
SSHDIR="/home/$TUNNEL_USER/.ssh"
mkdir -p "$SSHDIR"; chmod 700 "$SSHDIR"
AUTH="$SSHDIR/authorized_keys"
touch "$AUTH"

KEY_OPTIONS="restrict,port-forwarding"
if [[ -n "$REMOTE_ALLOW_FROM" ]]; then
  KEY_OPTIONS="$KEY_OPTIONS,from=\"$REMOTE_ALLOW_FROM\""
fi

if grep -qF "$PUBKEY" "$AUTH"; then
  if grep -qF "$KEY_OPTIONS $PUBKEY" "$AUTH"; then
    echo "    key already present with the current options"
  else
    grep -vF "$PUBKEY" "$AUTH" > "${AUTH}.tmp" || true
    mv "${AUTH}.tmp" "$AUTH"
    echo "$KEY_OPTIONS $PUBKEY" >> "$AUTH"
    echo "    key options updated"
  fi
else
  echo "$KEY_OPTIONS $PUBKEY" >> "$AUTH"
  echo "    key added"
fi
chown -R "$TUNNEL_USER:" "$SSHDIR"
chmod 600 "$AUTH"

echo "[3/4] Writing sshd configuration..."

SSHD=/etc/ssh/sshd_config
DDIR=/etc/ssh/sshd_config.d
BACKSUFFIX="pre-tunnel"

dropin_file() { # target drop-in path or "" when we must patch the base file
  if [[ -d "$DDIR" ]] && grep -q 'Include' "$SSHD" 2>/dev/null; then
    echo "$DDIR/60-socks-tunnel.conf"
  else
    echo ""
  fi
}

DROPIN="$(dropin_file)"

# Build the content that controls the tunnel user and optional hardening.
# global directives (outside Match) apply to everyone; the Match block for
# the tunnel user always ends with "Match all" so it cannot leak into
# following drop-in files.
LINES=()
if [[ "$SSH_HARDEN" == "1" ]]; then
  LINES+=( "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PermitRootLogin no" "PubkeyAuthentication yes" )
fi
if [[ "$SSH_ALLOW_USERS" == "1" ]]; then
  LINES+=( "AllowUsers $ADMIN_USER $TUNNEL_USER" )
fi

MATCH_LINE="Match User $TUNNEL_USER"
[[ -n "$REMOTE_ALLOW_FROM" ]] && MATCH_LINE="$MATCH_LINE Address $REMOTE_ALLOW_FROM"
LINES+=(
  ""
  "# Dedicated tunnel user - forwarding only (managed by setup-remote.sh)"
  "$MATCH_LINE"
  "    AuthenticationMethods publickey"
  "    PasswordAuthentication no"
  "    AllowTcpForwarding local"
  "Match all"
)
CONTENT="$(printf '# socks-tunnel - managed by setup-remote.sh, do not edit by hand\n%s\n' "$(printf '%s\n' "${LINES[@]}")")"

if [[ -n "$DROPIN" ]]; then
  # Backup the drop-in only the first time
  if [[ -f "$DROPIN" && ! -f "$DROPIN.bak.$BACKSUFFIX" ]]; then
    cp -a "$DROPIN" "$DROPIN.bak.$BACKSUFFIX"
    echo "    backup: $DROPIN.bak.$BACKSUFFIX"
  fi
  printf '%s' "$CONTENT" > "$DROPIN"
  chmod 644 "$DROPIN"
  echo "    wrote $DROPIN"
else
  if [[ ! -f "${SSHD}.bak.$BACKSUFFIX" ]]; then
    cp -a "$SSHD" "${SSHD}.bak.$BACKSUFFIX"
    echo "    backup: ${SSHD}.bak.$BACKSUFFIX"
  fi
  # Distro without sshd_config.d includes: append blocking rules at the end.
  printf '\n# --- socks-tunnel (managed by setup-remote.sh) ---\n%s' "$CONTENT" >> "$SSHD"
  echo "    appended to $SSHD (no sshd_config.d Include found)"
fi

sshd -t
echo "    config validated (sshd -t)"

echo "[4/4] Reloading SSH..."
reload_ssh() {
  if systemctl list-unit-files 2>/dev/null | grep -qE '^ssh\.service'; then
    systemctl reload ssh 2>/dev/null || { systemctl restart ssh; return 1; }
  elif systemctl list-unit-files 2>/dev/null | grep -qE '^sshd\.service'; then
    systemctl reload sshd 2>/dev/null || { systemctl restart sshd; return 1; }
  else
    service sshd reload 2>/dev/null || { service sshd restart; return 1; }
  fi
}
if reload_ssh; then
  echo "    reloaded (existing sessions kept)"
else
  echo "    reload unavailable, ssh restarted (existing sessions dropped)"
fi

if [[ "$INSTALL_FAIL2BAN" == "1" ]]; then
  echo "[-] fail2ban..."
  command -v fail2ban-client >/dev/null 2>&1 || apt-get update -qq && apt-get install -y -qq fail2ban
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
fi

if [[ "$ENABLE_UFW" == "1" ]]; then
  echo "[-] ufw..."
  if command -v ufw >/dev/null 2>&1; then
    if [[ -n "$UFW_ALLOW_FROM" ]]; then
      ufw allow from "$UFW_ALLOW_FROM" to any port "$SSH_PORT" proto tcp
    else
      ufw allow "$SSH_PORT"/tcp
    fi
    ufw --force enable
  else
    echo "    ufw not installed, skipping"
  fi
fi

echo
echo "Done. Tunnel user: $TUNNEL_USER"
echo "Source allow-list: ${REMOTE_ALLOW_FROM:-<any>}"
[[ "$SSH_ALLOW_USERS" == "1" ]] && echo "SSH restricted to users: $ADMIN_USER $TUNNEL_USER"
echo "Admin access kept for: $ADMIN_USER"
echo "Verify in a separate terminal that key-based login still works (passwords are now disabled)."