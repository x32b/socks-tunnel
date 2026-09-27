#!/usr/bin/env bash
# Local machine setup: generates the tunnel keypair and an SSH config block.
# Does NOT connect to the remote server - prints the public key to transfer manually.
#   ./setup-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

KEY="${LOCAL_KEY/#\~/$HOME}"

echo "[1/3] Generating tunnel keypair..."
if [[ ! -f "$KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "socks-tunnel" >/dev/null
  echo "    created $KEY"
else
  echo "    already exists: $KEY"
fi

echo "[2/3] Checking ~/.ssh/config..."
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
if ! grep -q "^Host $SSHCONFIG_HOST$" "$HOME/.ssh/config"; then
  cat >> "$HOME/.ssh/config" <<EOF

Host $SSHCONFIG_HOST
    HostName $REMOTE_HOST
    User $TUNNEL_USER
    Port $REMOTE_PORT
    IdentityFile $KEY
    DynamicForward $LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
    StrictHostKeyChecking accept-new
    SessionType none
EOF
  echo "    added Host block '$SSHCONFIG_HOST'"
else
  echo "    block already present, skipping"
fi

echo "[3/3] Public key to transfer to the server:"
echo
echo "  $KEY.pub"
echo "  ----------------------------------------------------------"
cat "$KEY.pub"
echo "  ----------------------------------------------------------"
echo
echo "Next, run the setup on the REMOTE server (manually, on that host):"
echo "  1. Copy setup-remote.sh and this key there (scp / web console)."
echo "  2. On the server run:"
echo "       sudo ./setup-remote.sh \"\$(cat tunnel.pub)\""
echo
echo "Back on the local machine:"
echo "  ./tunnel.sh start"
echo "  ./tunnel.sh check"
echo "  source $SCRIPT_DIR/proxy-env.sh   # then run opencode"