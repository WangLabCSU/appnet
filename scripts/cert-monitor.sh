#!/usr/bin/env bash
# cert-monitor — lisom.work 证书监控(每日 cron)
# 检查三件事:
#   1) 边缘(natcross)实际下发的证书指纹 == 本地 acme.sh 最新签发指纹?
#      不等 = "已续签未上架"(上架后边缘异步生效需 1–5 分钟,日检天然容忍)
#   2) 边缘证书链张数 >= 本地 fullchain 张数?(防"只贴了叶子证书"导致链不完整)
#   3) 本地证书剩余天数 < 阈值(默认 15)→ 告警
# 边缘 IP 不硬编码:每次重新解析域名当前 A 记录。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
NOTIFY="$SCRIPT_DIR/cert-notify.sh"
LOG_FILE="$BASE_DIR/logs/cert.log"
CERT="$HOME/.acme.sh/lisom.work/fullchain.cer"
HOSTS=(lisom.work csu.lisom.work)
THRESHOLD_DAYS=15
LOCAL_FP_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --threshold-days) THRESHOLD_DAYS="$2"; shift 2 ;;
        --local-fp)       LOCAL_FP_OVERRIDE="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

ts="$(date '+%F %T')"
mkdir -p "$(dirname "$LOG_FILE")"

local_fp() {
    if [ -n "$LOCAL_FP_OVERRIDE" ]; then echo "$LOCAL_FP_OVERRIDE"; return; fi
    openssl x509 -in "$CERT" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

edge_fp() {  # $1=hostname  $2=ip
    echo | timeout 20 openssl s_client -connect "$2:443" -servername "$1" 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

edge_chain() {  # $1=hostname  $2=ip → 链上证书张数
    echo | timeout 20 openssl s_client -connect "$2:443" -servername "$1" -showcerts 2>/dev/null \
        | grep -c 'BEGIN CERTIFICATE'
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
local_n="$(grep -c 'BEGIN CERTIFICATE' "$CERT" 2>/dev/null)"

alerts=""
for h in "${HOSTS[@]}"; do
    ip="$(dig +short "$h" A @223.5.5.5 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)"
    if [ -z "$ip" ]; then alerts="${alerts}[$h] DNS 解析失败; "; continue; fi
    ef="$(edge_fp "$h" "$ip")"
    if [ -z "$ef" ]; then
        alerts="${alerts}[$h] 边缘($ip)连接或证书读取失败; "
    elif [ "$ef" != "$lf" ]; then
        alerts="${alerts}[$h] 边缘证书与本地最新签发不一致(可能已续签未上架); "
    else
        en="$(edge_chain "$h" "$ip")"
        if [ "${en:-0}" -lt "${local_n:-0}" ]; then
            alerts="${alerts}[$h] 边缘证书链不完整(链上 ${en} 张 < 本地 ${local_n} 张,可能只贴了叶子证书); "
        fi
    fi
done

dl="$(days_left)"
if [ "$dl" -lt "$THRESHOLD_DAYS" ]; then
    alerts="${alerts}证书仅剩 ${dl} 天到期; "
fi

if [ -n "$alerts" ]; then
    echo "[$ts] ALERT: $alerts" >> "$LOG_FILE"
    "$NOTIFY" "⚠️ lisom 证书告警:${alerts}(本地指纹 ${lf:0:17}…)"
    exit 1
fi

echo "[$ts] OK: 两域名边缘指纹与证书链一致,本地证书剩 ${dl} 天" >> "$LOG_FILE"
if [ "$(date +%u)" = "1" ]; then   # 每周一心跳,防"监控静默死亡"
    "$NOTIFY" "✅ lisom 证书监控正常(本地证书剩 ${dl} 天)"
fi
exit 0
