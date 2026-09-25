#!/usr/bin/env bash
# Exports proxy env vars for the current shell (do NOT execute - source it):
#   source ~/socks-tunnel/proxy-env.sh
# After sourcing, every process started in this shell (including opencode)
# routes its internet traffic through the tunnel.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

if [[ "$PROXY_BRIDGE" == "1" ]]; then
  # Plain HTTP proxy (CONNECT) that forwards into the local SOCKS tunnel.
  if ! (exec 3<>"/dev/tcp/$LOCAL_SOCKS_ADDR/$BRIDGE_PORT") 2>/dev/null; then
    echo "WARN: HTTP bridge is not reachable at $LOCAL_SOCKS_ADDR:$BRIDGE_PORT." >&2
    echo "      Start it with:  ./tunnel.sh start   (bridge runs with PROXY_BRIDGE=1)" >&2
  fi
  PROXY_URL="http://$LOCAL_SOCKS_ADDR:$BRIDGE_PORT"
elif [[ "$PROXY_SOCKS5H" == "1" ]]; then
  # socks5h: resolve DNS on the remote server (no local DNS leak).
  # Tools that don't know "socks5h" resolve locally - see config.env.
  PROXY_URL="socks5h://$LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT"
else
  PROXY_URL="socks5://$LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT"
fi

export HTTPS_PROXY="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export ALL_PROXY="$PROXY_URL"
export NO_PROXY="localhost,127.0.0.1${PROXY_BYPASS:+,$PROXY_BYPASS}"

echo "Proxy env vars set to $PROXY_URL"
echo "NO_PROXY=$NO_PROXY"
