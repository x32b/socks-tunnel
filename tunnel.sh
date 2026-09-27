#!/usr/bin/env bash
# Tunnel control:  ./tunnel.sh {start|stop|restart|status|check|bridge-start|bridge-stop}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

RUN_DIR="$SCRIPT_DIR/run"
mkdir -p "$RUN_DIR"
PIDFILE="$RUN_DIR/tunnel.pid"
LOG="$RUN_DIR/tunnel.log"
BRIDGE_PIDFILE="$RUN_DIR/bridge.pid"
BRIDGE_LOG="$RUN_DIR/bridge.log"

is_running() {
  [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

is_bridge_running() {
  [[ -f "$BRIDGE_PIDFILE" ]] && kill -0 "$(cat "$BRIDGE_PIDFILE")" 2>/dev/null
}

bridge_start() {
  if [[ "$PROXY_BRIDGE" != "1" ]]; then
    echo "PROXY_BRIDGE is not enabled (config.env). Nothing to start."
    return 0
  fi
  if is_bridge_running; then
    echo "HTTP bridge already running (pid $(cat "$BRIDGE_PIDFILE")): $LOCAL_SOCKS_ADDR:$BRIDGE_PORT"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found - required for the HTTP bridge (bridge.py)." >&2
    return 1
  fi
  nohup python3 "$SCRIPT_DIR/bridge.py" \
      --port "$BRIDGE_PORT" \
      --socks "$LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT" \
      >/dev/null 2>"$BRIDGE_LOG" &
  echo $! > "$BRIDGE_PIDFILE"
  sleep 1
  if is_bridge_running; then
    echo "HTTP bridge started (pid $(cat "$BRIDGE_PIDFILE")): $LOCAL_SOCKS_ADDR:$BRIDGE_PORT -> socks $LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT"
  else
    echo "Failed to start the bridge. Log: $BRIDGE_LOG"; cat "$BRIDGE_LOG"; return 1
  fi
}

bridge_stop() {
  if is_bridge_running; then
    kill "$(cat "$BRIDGE_PIDFILE")" && echo "HTTP bridge stopped."
  else
    echo "HTTP bridge is not running."
  fi
  rm -f "$BRIDGE_PIDFILE"
}

cmd="${1:-status}"
case "$cmd" in
  start)
    if is_running; then
      echo "Tunnel already running (pid $(cat "$PIDFILE"))."
    else
      nohup ssh -N "$SSHCONFIG_HOST" >/dev/null 2>"$LOG" &
      echo $! > "$PIDFILE"
      sleep 2
      if is_running; then
        echo "Tunnel started (pid $(cat "$PIDFILE")): $LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT"
      else
        echo "Failed to start. Log: $LOG"; cat "$LOG"; exit 1
      fi
    fi
    bridge_start
    ;;
  stop)
    bridge_stop
    if is_running; then
      kill "$(cat "$PIDFILE")" && echo "Tunnel stopped."
    else
      echo "Tunnel is not running."
    fi
    rm -f "$PIDFILE"
    ;;
  restart)
    "$0" stop; "$0" start
    ;;
  bridge-start)
    bridge_start
    ;;
  bridge-stop)
    bridge_stop
    ;;
  status)
    if is_running; then
      echo "Tunnel: running (pid $(cat "$PIDFILE"))"
    else
      echo "Tunnel: not running"
    fi
    if command -v ss >/dev/null 2>&1; then
      if ss -tln | grep -qE ":$LOCAL_SOCKS_PORT " || command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$LOCAL_SOCKS_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "Port $LOCAL_SOCKS_PORT (socks): listening"
      else
        echo "Port $LOCAL_SOCKS_PORT (socks): NOT listening"
      fi
      if [[ "$PROXY_BRIDGE" == "1" ]]; then
        if ss -tln | grep -qE ":$BRIDGE_PORT " || command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
          echo "Port $BRIDGE_PORT (http bridge): listening"
        else
          echo "Port $BRIDGE_PORT (http bridge): NOT listening"
        fi
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
    echo "Usage: $0 {start|stop|restart|status|check|bridge-start|bridge-stop}"
    exit 1
    ;;
esac