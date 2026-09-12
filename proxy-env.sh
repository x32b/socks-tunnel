#!/usr/bin/env bash
# Источник прокси-переменных для текущей оболочки (не исполнять — source!):
#   source ~/socks-tunnel/proxy-env.sh
# После этого весь процесс, запущенный в этой оболочке (в т.ч. opencode),
# ходит в интернет через туннель.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

export HTTPS_PROXY="socks5://$LOCAL_SOCKS_ADDR:$LOCAL_SOCKS_PORT"
export HTTP_PROXY="$HTTPS_PROXY"
export ALL_PROXY="$HTTPS_PROXY"
export NO_PROXY="localhost,127.0.0.1"

echo "Прокси-переменные выставлены на $HTTPS_PROXY"
echo "NO_PROXY=$NO_PROXY"