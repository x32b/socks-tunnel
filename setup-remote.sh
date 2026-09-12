#!/usr/bin/env bash
# Setup for the REMOTE (relay) server.
# Runs directly ON the remote server, as root:
#
#   sudo ./setup-remote.sh "$(cat ~/tunnel.pub)"     # key passed inline
#   sudo ./setup-remote.sh ~/tunnel.pub               # key passed as a file
#
# The public key must be brought to the server manually (scp / web console).
set -euo pipefail

# ===== Settings (edit here or override via env vars) =====
TUNNEL_USER="${TUNNEL_USER:-tunnel}"        # dedicated user restricted to tunnelling
SSH_PORT="${SSH_PORT:-22}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-0}"   # 1 = install and enable fail2ban
ENABLE_UFW="${ENABLE_UFW:-0}"               # 1 = enable ufw (SSH only)
UFW_ALLOW_FROM="${UFW_ALLOW_FROM:-}"        # source IPs allowed for SSH, e.g. 1.2.3.4/32; empty = allow all
# ================================================================

# Whoever runs the script keeps working access after passwords are disabled
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
if ! grep -qF "$PUBKEY" "$AUTH"; then
  echo "restrict,port-forwarding $PUBKEY" >> "$AUTH"
  echo "    key added"
else
  echo "    key already present"
fi
chown -R "$TUNNEL_USER:" "$SSHDIR"
chmod 600 "$AUTH"

echo "[3/4] Hardening sshd..."
SSHD=/etc/ssh/sshd_config
if [[ ! -f "${SSHD}.bak.pre-tunnel" ]]; then
  cp -a "$SSHD" "${SSHD}.bak.pre-tunnel"
  echo "    backup: ${SSHD}.bak.pre-tunnel"
fi
set_opt() { # set_opt <key> <value> - updates or appends an sshd option
  local k="$1" v="$2"
  if grep -qE "^[# ]*${k}( |$)" "$SSHD"; then
    sed -i -E "s|^[# ]*${k}( |$).*|${k} ${v}|" "$SSHD"
  else
    echo "${k} ${v}" >> "$SSHD"
  fi
}
set_opt PasswordAuthentication no
set_opt KbdInteractiveAuthentication no
set_opt PermitRootLogin no
set_opt PubkeyAuthentication yes
set_opt AllowUsers "$ADMIN_USER $TUNNEL_USER"
sshd -t
echo "    config validated (sshd -t)"

echo "[4/4] Restarting SSH..."
if systemctl list-unit-files 2>/dev/null | grep -qE '^ssh\.service'; then
  systemctl restart ssh
elif systemctl list-unit-files 2>/dev/null | grep -qE '^sshd\.service'; then
  systemctl restart sshd
else
  service sshd restart
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
echo "Admin access kept for: $ADMIN_USER"
echo "Verify in a separate terminal that key-based login still works (passwords are now disabled)."