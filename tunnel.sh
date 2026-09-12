#!/usr/bin/env bash
# Tunnel control:  ./tunnel.sh {start|stop|restart|status|check}
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
      echo "Tunnel already running (pid $(cat "$PIDFILE"))."
      exit 0
    fi
    nohup ssh -N "$SSHCONFIG_HOST" >/dev/null 2>"$LOG" &
    echo $! > "$PIDFILE"
    sleep 2
    if is_running; then
      echo "Tunnel started (pid $(cat "$PIDFILE")): $LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT"
    else
      echo "Failed to start. Log: $LOG"; cat "$LOG"; exit 1
    fi
    ;;
  stop)
    if is_running; then
      kill "$(cat "$PIDFILE")" && echo "Stopped."
    else
      echo "Tunnel is not running."
    fi
    rm -f "$PIDFILE"
    ;;
  restart)
    "$0" stop; "$0" start
    ;;
  status)
    if is_running; then
      echo "Tunnel: running (pid $(cat "$PIDFILE"))"
    else
      echo "Tunnel: not running"
    fi
    if command -v ss >/dev/null 2>&1; then
      if ss -tln | grep -qE ":$LOCAL_SOCKS_PORT " || command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$LOCAL_SOCKS_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "Port $LOCAL_SOCKS_PORT: listening"
      else
        echo "Port $LOCAL_SOCKS_PORT: NOT listening"
      fi
    fi
    ;;
  check)
    if ! is_running; then
      echo "Tunnel is not running. Start it: $0 start"; exit 1
    fi
    out="$(curl -s --max-time 10 -x "socks5h://$LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT" https://api.ipify.org)" \
      && echo "Public IP through the tunnel: $out" \
      || { echo "Check failed - tunnel or network is down."; exit 1; }
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|check}"
    exit 1
    ;;
esac