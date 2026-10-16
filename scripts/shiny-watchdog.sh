#!/usr/bin/env bash
# Shiny Server 应用错误看门狗
#
# 用法：
#   shiny-watchdog.sh            只检查并报告
#   shiny-watchdog.sh --restart  发现故障时重启该应用的 R worker（自愈）
#
# 为什么不能只看 HTTP 状态码：Shiny Server 只要 R worker 还活着就返回 200，
# 即使应用每个会话都报错。2026-10-16 IOBRportal 就是这样坏的——extra-library
# 里的 readxl 被换掉后，长驻 worker 仍映射旧文件，任何读到它的会话都抛
# "lazy-load database ... is corrupt"，用户看到的是不断 "Attempting to
# reconnect"，而 warmup 日志一路报 8/8 OK，故障被瞒了一整天。
# 因此这里读的是应用自己的 worker 日志：新增错误行才是真信号。
#
# 自愈方式是杀掉该应用的 R worker（Shiny Server 收到下一个请求会自动拉起
# 新 worker，新 worker 重新映射当前文件）。带冷却期，避免应用启动慢时反复
# 被杀。命名约定同 check-apps.sh 的看门狗模式。
#
# 环境变量：
#   SHINY_CONTAINER        容器名（默认 shiny-server）
#   WATCHDOG_COOLDOWN_SECONDS  同一应用两次自愈的最小间隔（默认 1800）
#   ERROR_LINE_THRESHOLD   新增错误行达到该数量才判定故障（默认 5）

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$BASE_DIR/logs"
STATE_DIR="$LOG_DIR/.shiny-watch"
CONTAINER="${SHINY_CONTAINER:-shiny-server}"
COOLDOWN="${WATCHDOG_COOLDOWN_SECONDS:-1800}"
THRESHOLD="${ERROR_LINE_THRESHOLD:-5}"

RESTART=0
[ "${1:-}" = "--restart" ] && RESTART=1

mkdir -p "$STATE_DIR"

# 应用日志里算作「应用出错」的行；与普通启动信息区分开
ERROR_PATTERN='Error|error:|is corrupt|cannot open shared object|unable to load shared object|Execution halted'

# 枚举 Shiny 应用目录（排除日志目录）
list_apps() {
    docker exec "$CONTAINER" bash -c '
        for d in /srv/shiny-server/*/; do
            n=$(basename "$d")
            [ "$n" = "shiny_logs" ] && continue
            { [ -f "$d/app.R" ] || [ -f "$d/server.R" ] || [ -f "$d/ui.R" ]; } || continue
            echo "$n"
        done' 2>/dev/null
}

# 该应用当前 worker 的日志文件（最新一个）
current_log() {
    docker exec "$CONTAINER" bash -c "
        ls -t /srv/shiny-server/shiny_logs/$1-shiny-*.log 2>/dev/null | head -1" 2>/dev/null
}

# 杀掉某应用的 R worker；返回 0 表示确实杀掉了
restart_app_worker() {
    local app=$1
    docker exec "$CONTAINER" bash -c "
        killed=0
        for p in \$(ps -eo pid,args --no-headers | grep 'bin/exec/R' | grep -v grep | awk '{print \$1}'); do
            ppid=\$(ps -o ppid= -p \$p 2>/dev/null | tr -d ' ')
            # su 的 cmdline 里路径分隔符被转义成 \/，比对前先剥掉反斜杠
            parent=\$(tr '\0' ' ' < /proc/\$ppid/cmdline 2>/dev/null | sed 's|\\\\||g')
            # 以空格锚定应用名，避免 UCSCXenaShiny 误匹配 UCSCXenaShiny_basic
            case \"\$parent\" in
                *shiny-server/$app\\ *)
                    kill \$p 2>/dev/null && killed=1 ;;
            esac
        done
        [ \$killed = 1 ] && echo killed || echo none" 2>/dev/null
}

cooldown_elapsed() {
    local state_file="$STATE_DIR/.cooldown-$1"
    [ -f "$state_file" ] || return 0
    local last now
    last=$(cat "$state_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $((now - last)) -ge "$COOLDOWN" ]
}

APPS=$(list_apps)
if [ -z "$APPS" ]; then
    echo "shiny-watchdog: 无法枚举应用（容器 $CONTAINER 未运行？），本轮跳过" >&2
    exit 1
fi

FAULTS=0
for app in $APPS; do
    LOG=$(current_log "$app")
    if [ -z "$LOG" ]; then
        echo "  ⚠️  ${app}: 无 worker 日志（尚未被访问过？），跳过"
        continue
    fi

    SIZE=$(docker exec "$CONTAINER" stat -c %s "$LOG" 2>/dev/null || echo 0)
    STATE_FILE="$STATE_DIR/$app"
    PREV_LOG=""; PREV_SIZE=0
    if [ -f "$STATE_FILE" ]; then
        PREV_LOG=$(sed -n 1p "$STATE_FILE")
        PREV_SIZE=$(sed -n 2p "$STATE_FILE")
    fi

    # worker 换新日志文件（重启过）时，从 0 开始统计新日志
    [ "$PREV_LOG" != "$LOG" ] && PREV_SIZE=0

    if [ "$SIZE" -gt "$PREV_SIZE" ] 2>/dev/null; then
        NEW_ERRORS=$(docker exec "$CONTAINER" tail -c +"$((PREV_SIZE + 1))" "$LOG" 2>/dev/null \
            | grep -cE "$ERROR_PATTERN" || true)
    else
        NEW_ERRORS=0
    fi
    printf '%s\n%s\n' "$LOG" "$SIZE" > "$STATE_FILE"

    if [ "${NEW_ERRORS:-0}" -lt "$THRESHOLD" ]; then
        echo "  ✅ ${app}: 新增错误 ${NEW_ERRORS} 行（阈值 ${THRESHOLD}）"
        continue
    fi

    FAULTS=$((FAULTS + 1))
    echo "  ❌ ${app}: 新增错误 ${NEW_ERRORS} 行 → 应用在报错（日志 $LOG）"

    if [ "$RESTART" = "0" ]; then
        continue
    fi
    if ! cooldown_elapsed "$app"; then
        echo "     ⏭️  仍在冷却期内（${COOLDOWN}s），跳过重启"
        continue
    fi
    date +%s > "$STATE_DIR/.cooldown-$app"
    RESULT=$(restart_app_worker "$app")
    if [ "$RESULT" = "killed" ]; then
        echo "     🔄 已终止 ${app} 的 R worker，Shiny Server 将在下次请求时拉起新进程"
    else
        echo "     ⚠️  未找到 ${app} 的 R worker（可能本就未运行）"
    fi
done

if [ "$FAULTS" -gt 0 ]; then
    echo "shiny-watchdog: ${FAULTS} 个应用报错"
    exit 1
fi
echo "shiny-watchdog: 所有应用日志无新增错误 ✓"
exit 0
