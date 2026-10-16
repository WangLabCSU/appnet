#!/usr/bin/env bash
# bizard-mcp 启动脚本（幂等：已在跑则直接跳过，可被 appnet start 重复调用）
#
# 首次运行自动完成（此后增量、快速返回）：
#   1. 保证 Node>=20（系统无则用户态引导 ~/.local/node20，免 sudo）
#   2. 浅克隆 openbiox/Bizard 到 repo/（不入库，.gitignore 排除；优先走 apps.yaml 的 github_proxy）
#   3. npm ci（只读 lockfile）+ build:bundle（生成图表内容快照）+ build（tsc 编译 + 拷贝快照）
#   4. 以 Streamable HTTP 模式拉起，监听 BIZARD_HTTP_PORT（默认 28892）
#
# 代码自动更新不在此脚本负责：appnet update-app（git_pull_npm）拉新代码后重建并重启。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$DIR/../.." && pwd)"
PID_FILE="$DIR/bizard-mcp.pid"
LOG_FILE="$DIR/service.log"
PORT="${BIZARD_HTTP_PORT:-28892}"
REPO_DIR="$DIR/repo"
MCP_DIR="$REPO_DIR/mcp"
BIZARD_REPO_URL="${BIZARD_REPO_URL:-https://github.com/openbiox/Bizard.git}"

# Node >= 20（bizard-mcp engines 要求）
# shellcheck source=../../scripts/node-env.sh
source "$BASE_DIR/scripts/node-env.sh"
ensure_node20

# 快路径：已在跑则跳过（断电恢复 / appnet start 全部应用时无需重复构建）
#
# 必须校验 PID 身份，不能只看 kill -0：PID 会被无关进程复用，此时快路径会
# 误判「已在运行」直接退出——服务实际是停的，却对外报告启动成功，且此后
# 每次 start 都被这个陈旧 PID 挡住（2026-10-16 排查时发现的同类陷阱）。
mcp_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # 确认是自己那个 node 进程：/proc/<pid>/cmdline 应指向本应用的 dist/index.js
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$MCP_DIR/dist/index.js"
}

if mcp_running; then
    echo "already running (pid $(cat "$PID_FILE"))"
    exit 0
fi

# 首次：克隆 Bizard 仓库（浅克隆；github_proxy 加速失败则直连兜底）
if [ ! -d "$REPO_DIR/.git" ]; then
    proxy="$(python3 -c "import yaml;print(yaml.safe_load(open('$BASE_DIR/config/apps.yaml')).get('global',{}).get('github_proxy','') or '')" 2>/dev/null || true)"
    echo "cloning Bizard -> $REPO_DIR"
    git clone --depth 20 "${proxy}${BIZARD_REPO_URL}" "$REPO_DIR" 2>/dev/null \
        || git clone --depth 20 "$BIZARD_REPO_URL" "$REPO_DIR"
fi

# npm 国内镜像（可选；apps.yaml global.npm_registry，留空用 npm 默认源）
# npm ci 只读 lockfile 安装（可复现、且不改动克隆工作区，保证后续 git pull 永远干净）
npm_mirror="$(python3 -c "import yaml;print(yaml.safe_load(open('$BASE_DIR/config/apps.yaml')).get('global',{}).get('npm_registry','') or '')" 2>/dev/null || true)"
npm_install=(npm ci --no-audit --no-fund)
[ -n "$npm_mirror" ] && npm_install+=(--registry "$npm_mirror")

cd "$MCP_DIR"

# 依赖：node_modules 缺失或 lock 更新后未重装 → npm install
if [ ! -d node_modules ] || [ package-lock.json -nt node_modules/.package-lock.json ]; then
    echo "npm install ..."
    "${npm_install[@]}"
fi

# 构建：dist 缺失，或 src/package.json/package-lock.json 任一更新 → 重建。
# build:bundle 从仓库内容（画廊 CSV + 教程 QMD）生成 src/snapshot；
# build = tsc + 拷贝快照到 dist（bundle.ts 从 dist/snapshot/bundle.json 加载）。
if [ ! -f dist/index.js ] || [ ! -f dist/snapshot/bundle.json ] \
    || [ -n "$(find src package.json package-lock.json -newer dist/index.js 2>/dev/null | head -1)" ]; then
    echo "building bizard-mcp ..."
    npm run build:bundle
    npm run build
fi

cd "$DIR"
# 反代（Caddy）在后：按 X-Forwarded-For 末跳做 per-IP 限流，
# 否则所有请求都算 127.0.0.1，全站共享一个限流桶。
BIZARD_TRUST_PROXY=1 BIZARD_HTTP_PORT="$PORT" \
    nohup node "$MCP_DIR/dist/index.js" --http >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
echo "started (pid $(cat "$PID_FILE"), listen :$PORT, repo $(git -C "$REPO_DIR" rev-parse --short HEAD))"
