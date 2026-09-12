#!/usr/bin/env bash
# Exports proxy env vars for the current shell (do NOT execute - source it):
#   source ~/socks-tunnel/proxy-env.sh
# After sourcing, every process started in this shell (including opencode)
# routes its internet traffic through the tunnel.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

export HTTPS_PROXY="socks5://$LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT"
export HTTP_PROXY="$HTTPS_PROXY"
export ALL_PROXY="$HTTPS_PROXY"
export NO_PROXY="localhost,127.0.0.1"

echo "Proxy env vars set to $HTTPS_PROXY"
echo "NO_PROXY=$NO_PROXY"