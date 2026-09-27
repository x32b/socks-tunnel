#!/usr/bin/env bash
# Tunnel control:  ./tunnel.sh {start|stop|restart|status|check|install|uninstall}
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
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    return 0
  fi
  pgrep -f "ssh -N $SSHCONFIG_HOST" >/dev/null 2>&1
}

is_bridge_running() {
  if [[ -f "$BRIDGE_PIDFILE" ]] && kill -0 "$(cat "$BRIDGE_PIDFILE")" 2>/dev/null; then
    return 0
  fi
  [[ "$PROXY_BRIDGE" == "1" ]] && pgrep -f "$SCRIPT_DIR/bridge.py" >/dev/null 2>&1
}

systemd_managed() {
  systemctl --user is-active socks-tunnel.service >/dev/null 2>&1
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

install_profile() {
  # exports proxy vars in interactive shells only when the tunnel port responds
  local port="$1" marker="# >>> socks-tunnel >>>" trailer="# <<< socks-tunnel <<<"
  for f in "$HOME/.bashrc" "$HOME/.profile"; do
    [[ -f "$f" ]] || touch "$f"
    if grep -qF "$marker" "$f"; then
      sed -i "/$marker/,/$trailer/d" "$f"
    fi
    cat >> "$f" <<EOF

$marker
if (exec 3<>"/dev/tcp/$LOCAL_SOCKS_ADDR/$port") 2>/dev/null; then
  source "$SCRIPT_DIR/proxy-env.sh"
fi
$trailer
EOF
  done
  echo "    profile vars: $LOCAL_SOCKS_ADDR:$port (conditional on port)"
}

install_services() {
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  local bash_bin python_bin
  bash_bin="$(command -v bash)"
  python_bin="$(command -v python3 || echo python3)"

  cat > "$UNIT_DIR/socks-tunnel.service" <<EOF
[Unit]
Description=SOCKS tunnel to $REMOTE_HOST ($SSHCONFIG_HOST)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$bash_bin -lc 'source "$SCRIPT_DIR/config.env" && exec ssh -N "\$SSHCONFIG_HOST"'
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

  if [[ "$PROXY_BRIDGE" == "1" ]]; then
    cat > "$UNIT_DIR/socks-bridge.service" <<EOF
[Unit]
Description=HTTP CONNECT -> SOCKS5 bridge for opencode
After=socks-tunnel.service
Wants=socks-tunnel.service

[Service]
Type=simple
ExecStart=$python_bin "$SCRIPT_DIR/bridge.py" --addr "$LOCAL_SOCKS_ADDR" --port "$BRIDGE_PORT" --socks "$LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT"
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  else
    rm -f "$UNIT_DIR/socks-bridge.service"
  fi

  systemctl --user daemon-reload
  systemctl --user enable --now socks-tunnel.service
  [[ "$PROXY_BRIDGE" == "1" ]] && systemctl --user enable --now socks-bridge.service
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  echo "    systemd user services: socks-tunnel.service + ${PROXY_BRIDGE:+socks-bridge.service} (linger on)"
}

cmd="${1:-status}"
case "$cmd" in
  install)
    bridge_port=("$LOCAL_SOCKS_PORT")
    [[ "$PROXY_BRIDGE" == "1" ]] && bridge_port=("$BRIDGE_PORT")
    install_profile "${bridge_port[0]}"
    install_services
    echo "Done. Tunnel autostarts on login; no per-shell commands needed."
    ;;
  uninstall)
    systemctl --user disable --now socks-tunnel.service socks-bridge.service >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/socks-tunnel.service" \
          "$HOME/.config/systemd/user/socks-bridge.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    for f in "$HOME/.bashrc" "$HOME/.profile"; do
      [[ -f "$f" ]] || continue
      if grep -qF "# >>> socks-tunnel >>>" "$f"; then
        sed -i '/# >>> socks-tunnel >>>/,/# <<< socks-tunnel <<</d' "$f"
        echo "    cleaned $f"
      fi
    done
    "$0" stop
    echo "Done. Autostart and proxy profile settings removed."
    ;;
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
    if systemd_managed; then
      echo "Tunnel is managed by systemd (linger+autostart)."
      echo "Use:  systemctl --user stop socks-tunnel.service socks-bridge.service"
      echo "       (or ./tunnel.sh uninstall to remove autostart entirely)"
      exit 0
    fi
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
      if systemd_managed; then
        echo "Tunnel: running (systemd user service socks-tunnel.service)"
      elif [[ -f "$PIDFILE" ]]; then
        echo "Tunnel: running (pid $(cat "$PIDFILE"))"
      else
        echo "Tunnel: running"
      fi
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
    echo "Usage: $0 {start|stop|restart|status|check|bridge-start|bridge-stop|install|uninstall}"
    exit 1
    ;;
esac