#!/usr/bin/env bash
# websearch-mcp 团队共享服务启动（幂等：已在跑则直接跳过，可被 appnet start 重复调用）
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$DIR/websearch.pid"
LISTEN="127.0.0.1:28891"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PID_FILE"))"
    exit 0
fi

# token 不入库（.env 已被 appnet .gitignore 的 apps/*/.env 规则覆盖）
# shellcheck disable=SC1091
[ -f "$DIR/.env" ] && . "$DIR/.env"
: "${WEBSEARCH_TOKEN:?缺 WEBSEARCH_TOKEN：写在本目录 .env（WEBSEARCH_TOKEN=...，0600）}"

cd "$DIR"
nohup python3 "$DIR/websearch-mcp.py" --http "$LISTEN" \
    --token "$WEBSEARCH_TOKEN" >> "$DIR/service.log" 2>&1 &
echo $! > "$PID_FILE"
echo "started (pid $(cat "$PID_FILE"), listen $LISTEN)"
