#!/usr/bin/env bash
# AppNet 应用健康检查 / 自愈看门狗
#
# 两种用法：
#   1. check-apps.sh
#      一次性检查（systemd appnet-apps.service 的 ExecStartPost 调用）。
#      从 config/apps.yaml 读所有 enabled 且非 proxy/redirect/static 的应用端口，
#      用 ss 验证端口监听。全部 LISTEN 返回 0，超时仍有端口未监听返回 1。
#
#   2. check-apps.sh --restart
#      看门狗（cron 周期调用）：对「端口未监听」的应用执行 appnet restart 自愈。
#      每个应用有冷却期（默认 900 秒），期内不重复重启——否则应用启动慢时
#      会被反复杀掉重启，陷入 2026-10-15 断电事故那样的重启循环。
#
# 冷启动宽限：应用启动后端口需要数秒到数十秒才就绪（uvicorn 加载模型、
# npm 冷启动等）。ExecStartPost 一旦返回非 0，systemd 会杀掉整个 cgroup
# 并按 Restart=on-failure 重试——无宽限的即时检查在断电重启后必然陷入
# 无限重启循环（2026-10-15 断电后实测重启计数 7600+）。因此这里每 2 秒
# 重扫一次端口，最长等待 GRACE_SECONDS。
#
# 环境变量：
#   GRACE_SECONDS              端口就绪宽限（默认 90，看门狗模式默认 30）
#   WATCHDOG_COOLDOWN_SECONDS  同一应用两次自愈重启的最小间隔（默认 900）

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$BASE_DIR/config/apps.yaml"
WATCHDOG=0
[ "${1:-}" = "--restart" ] && WATCHDOG=1

if [ "$WATCHDOG" = "1" ]; then
    GRACE_SECONDS="${GRACE_SECONDS:-30}"
else
    GRACE_SECONDS="${GRACE_SECONDS:-90}"
fi
WATCHDOG_COOLDOWN_SECONDS="${WATCHDOG_COOLDOWN_SECONDS:-900}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "check-apps: config not found: $CONFIG_FILE" >&2
    exit 1
fi

# 端口扫描：打印 "port app" 行，只保留当前未监听的端口
not_listening_ports() {
    CONFIG_FILE="$CONFIG_FILE" python3 - << 'PYTHON_SCRIPT'
import os
import subprocess
import yaml

with open(os.environ['CONFIG_FILE']) as f:
    config = yaml.safe_load(f)

seen = set()
for app in config.get('apps', []):
    if app.get('enabled', True) is False:
        continue
    # proxy/redirect/static 不需要后端进程
    if app.get('type') in ('proxy', 'redirect', 'static'):
        continue
    name = app.get('name')
    for route in app.get('routes', []):
        target = route.get('target', '')
        if ':' in target and 'localhost' in target:
            port = target.split(':')[-1]
            if port and port not in seen:
                seen.add(port)
                r = subprocess.run(['ss', '-ltnH', f'sport = :{port}'],
                                   capture_output=True, text=True)
                if not r.stdout.strip():
                    print(f"{port} {name}")
PYTHON_SCRIPT
}

# 冷却检查：期内返回 0（可重启），否则返回 1（跳过）
cooldown_elapsed() {
    local name=$1 state_file="$BASE_DIR/logs/.watchdog-$1"
    [ -f "$state_file" ] || return 0
    local last now
    last=$(cat "$state_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $((now - last)) -ge "$WATCHDOG_COOLDOWN_SECONDS" ]
}

# 等待端口就绪；全部就绪返回 0
wait_for_ports() {
    local deadline=$((SECONDS + GRACE_SECONDS))
    while :; do
        [ -z "$(not_listening_ports)" ] && return 0
        [ "$SECONDS" -ge "$deadline" ] && return 1
        sleep 2
    done
}

echo "check-apps: 检查应用端口（宽限 ${GRACE_SECONDS}s，模式 $([ "$WATCHDOG" = 1 ] && echo 看门狗 || echo 一次性)）..."

if wait_for_ports; then
    echo "check-apps: all apps listening ✓"
    exit 0
fi

PENDING=$(not_listening_ports)

# --- 一次性模式：报错退出（systemd 依据退出码决定是否重启整个服务） ---
if [ "$WATCHDOG" = "0" ]; then
    while read -r port name; do
        [ -n "$port" ] && echo "  ❌ $name :$port NOT listening" >&2
    done <<< "$PENDING"
    echo "check-apps: FAILED — ports not listening: $(echo "$PENDING" | awk '{print $1}' | tr '\n' ' ')" >&2
    exit 1
fi

# --- 看门狗模式：逐个自愈重启（带冷却），退出码恒为 0 以免 cron 报错噪音 ---
mkdir -p "$BASE_DIR/logs"
while read -r port name; do
    [ -z "$port" ] && continue
    if ! cooldown_elapsed "$name"; then
        echo "  ⏭️  $name :$port 未监听，但仍在冷却期内（${WATCHDOG_COOLDOWN_SECONDS}s），跳过"
        continue
    fi
    echo "  🔄 $name :$port 未监听 → 执行 appnet restart $name"
    date +%s > "$BASE_DIR/logs/.watchdog-$name"
    # 变量一律用 ${name} 界定：紧跟全角标点时 bash 会把多字节字符的首字节
    # 并进变量名，报 "name: unbound variable" 并在 set -u 下直接中止。
    if "$BASE_DIR/scripts/app-manager.sh" restart "$name" >> "$BASE_DIR/logs/watchdog.log" 2>&1; then
        echo "     ✓ 已重启 ${name}（详见 logs/watchdog.log）"
    else
        echo "     ✗ 重启 ${name} 失败（详见 logs/watchdog.log）"
    fi
done <<< "$PENDING"

exit 0
