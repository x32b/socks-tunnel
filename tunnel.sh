#!/usr/bin/env bash
# Управление туннелем:  ./tunnel.sh {start|stop|restart|status|check}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

RUN_DIR="$SCRIPT_DIR/run"
mkdir -p "$RUN_DIR"
PIDFILE="$RUN_DIR/tunnel.pid"
LOG="$RUN_DIR/tunnel.log"

is_running() {
  [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

cmd="${1:-status}"
case "$cmd" in
  start)
    if is_running; then
      echo "Туннель уже работает (pid $(cat "$PIDFILE"))."
      exit 0
    fi
    nohup ssh -N "$SSHCONFIG_HOST" >/dev/null 2>"$LOG" &
    echo $! > "$PIDFILE"
    sleep 2
    if is_running; then
      echo "Туннель запущен (pid $(cat "$PIDFILE")): $LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT"
    else
      echo "Не удалось запустить, лог: $LOG"; cat "$LOG"; exit 1
    fi
    ;;
  stop)
    if is_running; then
      kill "$(cat "$PIDFILE")" && echo "Остановлен."
    else
      echo "Туннель не запущен."
    fi
    rm -f "$PIDFILE"
    ;;
  restart)
    "$0" stop; "$0" start
    ;;
  status)
    if is_running; then
      echo "Туннель: запущен (pid $(cat "$PIDFILE"))"
    else
      echo "Туннель: не запущен"
    fi
    if command -v ss >/dev/null 2>&1; then
      if ss -tln | grep -qE ":$LOCAL_SOCKS_PORT " || command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$LOCAL_SOCKS_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "Порт $LOCAL_SOCKS_PORT: слушается"
      else
        echo "Порт $LOCAL_SOCKS_PORT: НЕ слушается"
      fi
    fi
    ;;
  check)
    if ! is_running; then
      echo "Туннель не запущен. Запусти: $0 start"; exit 1
    fi
    out="$(curl -s --max-time 10 -x "socks5h://$LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT" https://api.ipify.org)" \
      && echo "Внешний IP через туннель: $out" \
      || { echo "Проверка не прошла — туннель или сеть не работает."; exit 1; }
    ;;
  *)
    echo "Использование: $0 {start|stop|restart|status|check}"
    exit 1
    ;;
esac