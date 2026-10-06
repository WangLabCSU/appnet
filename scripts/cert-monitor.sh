#!/usr/bin/env bash
# cert-monitor — lisom.work 证书监控(每日 cron)
# 检查四件事:
#   1) 边缘(natcross)实际下发的证书指纹 == 本地 acme.sh 最新签发指纹?
#      不等 = "已续签未上架"(上架后边缘异步生效需 1–5 分钟,日检天然容忍)
#   2) 边缘链是否只下发了叶子证书(en<=1 告警;en=0 归"核验异常",不再误诊为链截断)
#   3) acme.sh 续期钩子(reloadcmd)存在且可执行?(防仓库迁移后交付静默失效)
#   4) 本地证书剩余天数 < 阈值(默认 15)→ 告警
# 成功路径每日发一条心跳(dead-man's switch):消息断更本身即是"监控/通道异常"的信号。
# 边缘 IP 不硬编码:每次解析域名当前 A 记录(优先系统解析器,失败回退公共 DNS)。
set -u
umask 027

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
NOTIFY="$SCRIPT_DIR/cert-notify.sh"
LOG_FILE="$BASE_DIR/logs/cert.log"
CERT="$HOME/.acme.sh/lisom.work/fullchain.cer"
CONF="$HOME/.acme.sh/lisom.work/lisom.work.conf"
HOSTS=(lisom.work csu.lisom.work)
THRESHOLD_DAYS=15
LOCAL_FP_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --threshold-days)
            [ $# -ge 2 ] || { echo "--threshold-days 需要一个值" >&2; exit 2; }
            THRESHOLD_DAYS="$2"; shift 2 ;;
        --local-fp)
            [ $# -ge 2 ] || { echo "--local-fp 需要一个值" >&2; exit 2; }
            LOCAL_FP_OVERRIDE="$2"; shift 2 ;;   # 仅供测试:注入本地指纹以模拟异常
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

case "$THRESHOLD_DAYS" in
    ''|*[!0-9]*) echo "--threshold-days 需为非负整数" >&2; exit 2 ;;
esac

ts="$(date '+%F %T')"
prefix=""
[ "${NOTIFY_DRY_RUN:-0}" = "1" ] && prefix="[DRY-RUN] "
mkdir -p "$(dirname "$LOG_FILE")"

local_fp() {
    if [ -n "$LOCAL_FP_OVERRIDE" ]; then echo "$LOCAL_FP_OVERRIDE"; return; fi
    openssl x509 -in "$CERT" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

edge_fp() {  # $1=hostname  $2=ip
    echo | timeout 20 openssl s_client -connect "$2:443" -servername "$1" 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

edge_chain() {  # $1=hostname  $2=ip → 链上证书张数(失败时输出 0)
    echo | timeout 20 openssl s_client -connect "$2:443" -servername "$1" -showcerts 2>/dev/null \
        | grep -c 'BEGIN CERTIFICATE'
}

resolve_a() {  # $1=hostname → IPv4(系统解析器优先,公共 DNS 回退)
    local ip
    ip="$(dig +short "$1" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)"
    if [ -z "$ip" ]; then
        ip="$(dig +short "$1" A @223.5.5.5 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)"
    fi
    echo "$ip"
}

reload_ok() {  # acme.sh 续期钩子可执行?(conf 内通常为 base64 编码;无标记时按原值处理)
    local cmd path
    cmd="$(grep -E '^Le_ReloadCmd=' "$CONF" 2>/dev/null | sed 's/^Le_ReloadCmd=//' | tr -d "\047")"
    [ -n "$cmd" ] || return 1
    case "$cmd" in
        *__ACME_BASE64__START_*__ACME_BASE64__END_*)
            path="$(printf '%s' "$cmd" | sed 's/^__ACME_BASE64__START_//; s/__ACME_BASE64__END_$//' | base64 -d 2>/dev/null)" ;;
        *)
            path="$cmd" ;;
    esac
    [ -n "$path" ] && [ -x "$path" ]
}

days_left() {
    local end end_epoch
    end="$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
    end_epoch="$(date -d "$end" +%s 2>/dev/null)" || { echo -1; return; }
    echo $(( (end_epoch - $(date +%s)) / 86400 ))
}

lf="$(local_fp)"
if [ -z "$lf" ]; then
    "$NOTIFY" "❌ lisom 证书监控:本地证书读取失败($CERT)"
    exit 1
fi

alerts=""
if ! reload_ok; then
    alerts="${alerts}acme.sh reloadcmd 缺失或不可执行(续期交付不会触发); "
fi

for h in "${HOSTS[@]}"; do
    ip="$(resolve_a "$h")"
    if [ -z "$ip" ]; then alerts="${alerts}[$h] DNS 解析失败; "; continue; fi
    ef="$(edge_fp "$h" "$ip")"
    if [ -z "$ef" ]; then
        alerts="${alerts}[$h] 边缘($ip)连接或证书读取失败; "
    elif [ "$ef" != "$lf" ]; then
        alerts="${alerts}[$h] 边缘证书与本地最新签发不一致(可能已续签未上架); "
    else
        en="$(edge_chain "$h" "$ip")"
        if [ "${en:-0}" -eq 0 ]; then
            alerts="${alerts}[$h] 边缘链核验异常(连接抖动或未下发证书链,建议人工复核); "
        elif [ "${en:-0}" -le 1 ]; then
            alerts="${alerts}[$h] 边缘只下发了叶子证书(链不完整,可能上架时未贴全); "
        fi
    fi
done

dl="$(days_left)"
if [ "$dl" -lt "$THRESHOLD_DAYS" ]; then
    alerts="${alerts}证书仅剩 ${dl} 天到期; "
fi

if [ -n "$alerts" ]; then
    echo "[$ts] ${prefix}ALERT: $alerts" >> "$LOG_FILE"
    "$NOTIFY" "⚠️ lisom 证书告警:${alerts}(本地指纹 ${lf:0:17}…)"
    exit 1
fi

echo "[$ts] ${prefix}OK: 两域名边缘指纹与证书链一致,本地证书剩 ${dl} 天" >> "$LOG_FILE"
# 每日心跳(dead-man's switch):若无此消息,即说明监控或通知通道已异常
"$NOTIFY" "✅ lisom 证书监控心跳:剩 ${dl} 天(每日一条,断更即异常)"
exit 0
