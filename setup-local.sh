#!/usr/bin/env bash
# Настройка ЛОКАЛЬНОЙ машины: генерирует ключ туннеля и блок в ~/.ssh/config.
# НЕ подключается к зарубежному серверу — ключ выводится для переноса самому.
#   ./setup-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

KEY="${LOCAL_KEY/#\~/$HOME}"

echo "[1/3] Генерирую ключ для туннеля..."
if [[ ! -f "$KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "socks-tunnel" >/dev/null
  echo "    создан $KEY"
else
  echo "    уже есть $KEY"
fi

echo "[2/3] Проверяю ~/.ssh/config..."
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
    SessionType none
EOF
  echo "    добавлен блок Host $SSHCONFIG_HOST"
else
  echo "    блок уже есть, пропускаю"
fi

echo "[3/3] Публичный ключ для переноса на сервер:"
echo
echo "  $KEY.pub"
echo "  ----------------------------------------------------------"
cat "$KEY.pub"
echo "  ----------------------------------------------------------"
echo
echo "Дальше сделай сам на ЗАРУБЕЖНОМ сервере:"
echo "  1. Перенеси туда setup-remote.sh и этот ключ (scp/консоль)."
echo "  2. На сервере выполни:"
echo "       sudo ./setup-remote.sh \"\$(cat tunnel.pub)\""
echo
echo "После этого на локальной машине:"
echo "  ./tunnel.sh start"
echo "  ./tunnel.sh check"
echo "  source $SCRIPT_DIR/proxy-env.sh   # а затем opencode"