#!/usr/bin/env bash
# Настройка ЗАРУБЕЖНОГО сервера (второй сервер).
# Запускается НАПРЯМУЮ на зарубежном сервере, от sudo:
#
#   sudo ./setup-remote.sh "$(cat ~/tunnel.pub)"     # ключ строкой
#   sudo ./setup-remote.sh ~/tunnel.pub               # ключ файлом
#
# Публичный ключ нужно принести на сервер самому (scp/консоль/copy-paste).
set -euo pipefail

# ===== Настройки (можно менять здесь или env-переменными) =====
TUNNEL_USER="${TUNNEL_USER:-tunnel}"        # пользователь только для туннеля
SSH_PORT="${SSH_PORT:-22}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-0}"   # 1 = поставить и включить fail2ban
ENABLE_UFW="${ENABLE_UFW:-0}"               # 1 = включить ufw (только SSH)
UFW_ALLOW_FROM="${UFW_ALLOW_FROM:-}"        # откуда разрешить SSH, напр. 1.2.3.4/32; пусто = отовсюду
# ================================================================

# Кто запускает скрипт — ему оставляем рабочий вход после запрета паролей
ADMIN_USER="$(id -un)"
if [[ ${SUDO_USER:-unset} != "unset" && -n "$SUDO_USER" ]]; then
  ADMIN_USER="$SUDO_USER"
fi

if [[ $EUID -ne 0 ]]; then
  echo "Запусти от root:   sudo $0 '<публичный ключ>'" >&2
  exit 1
fi

USAGE="Использование: sudo $0 '<ssh-ed25519 AA... комментарий>' | sudo $0 /путь/к/файлу.pub"
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
  echo "Аргумент не похож ни на ключ, ни на существующий файл: $1" >&2
  exit 1
fi
case "$PUBKEY" in
  ssh-*) ;;
  *) echo "Ошибка: ключ должен начинаться с 'ssh-...'" >&2; exit 1 ;;
esac

NOLOGIN="$(command -v nologin || echo /usr/sbin/nologin)"

echo "[1/4] Пользователь туннеля '$TUNNEL_USER'..."
if id "$TUNNEL_USER" >/dev/null 2>&1; then
  echo "    уже существует"
else
  useradd -m -s "$NOLOGIN" "$TUNNEL_USER"
  echo "    создан"
fi
usermod -s "$NOLOGIN" "$TUNNEL_USER"

echo "[2/4] Устанавливаю ограниченный ключ..."
SSHDIR="/home/$TUNNEL_USER/.ssh"
mkdir -p "$SSHDIR"; chmod 700 "$SSHDIR"
AUTH="$SSHDIR/authorized_keys"
touch "$AUTH"
if ! grep -qF "$PUBKEY" "$AUTH"; then
  echo "restrict,port-forwarding $PUBKEY" >> "$AUTH"
  echo "    ключ добавлен"
else
  echo "    ключ уже есть"
fi
chown -R "$TUNNEL_USER:" "$SSHDIR"
chmod 600 "$AUTH"

echo "[3/4] Усиливаю sshd..."
SSHD=/etc/ssh/sshd_config
if [[ ! -f "${SSHD}.bak.pre-tunnel" ]]; then
  cp -a "$SSHD" "${SSHD}.bak.pre-tunnel"
  echo "    бэкап: ${SSHD}.bak.pre-tunnel"
fi
set_opt() { # set_opt <ключ> <значение> — правит или дописывает параметр sshd
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
echo "    конфиг проверен (sshd -t)"

echo "[4/4] Перезапуск SSH..."
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
    echo "    ufw не установлен, пропускаю"
  fi
fi

echo
echo "Готово. Туннель-пользователь: $TUNNEL_USER"
echo "Админ-доступ сохранён за: $ADMIN_USER"
echo "Проверь в отдельном терминале, что вход по ключу всё ещё работает (пароль теперь выключен)."