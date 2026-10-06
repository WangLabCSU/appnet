#!/usr/bin/env bash
# cert-notify — 证书自动化统一通知出口
# 用法: cert-notify.sh "消息内容"
# 行为: 始终追加 logs/cert.log;若 ~/manage/secrets/lisom.env 配置了
#       WECOM_WEBHOOK 则推送企业微信群机器人;未配置/失败时仅记日志,不报错。
# 安全: 本文件不得出现任何凭据;消息内容不得包含 token/webhook(spec §8)。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$BASE_DIR/logs/cert.log"
SECRETS_FILE="$HOME/manage/secrets/lisom.env"

msg="${1:-}"
if [ -z "$msg" ]; then
    echo "用法: cert-notify.sh \"消息内容\"" >&2
    exit 1
fi

ts="$(date '+%F %T')"
mkdir -p "$(dirname "$LOG_FILE")"
echo "[$ts] $msg" >> "$LOG_FILE"

WECOM_WEBHOOK=""
[ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"

payload="$(python3 -c 'import json,sys; print(json.dumps({"msgtype":"text","text":{"content":sys.argv[1]}}, ensure_ascii=False))' "$msg")"

if [ "${NOTIFY_DRY_RUN:-0}" = "1" ]; then
    echo "[cert-notify][dry-run] $payload"
    exit 0
fi

if [ -z "${WECOM_WEBHOOK:-}" ]; then
    echo "[cert-notify] 未配置 WECOM_WEBHOOK,仅记录日志" >&2
    exit 0
fi

http_code="$(timeout 15 curl -s -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' -d "$payload" "$WECOM_WEBHOOK" || echo 000)"
if [ "$http_code" != "200" ]; then
    echo "[$ts] 通知发送失败 HTTP=$http_code" >> "$LOG_FILE"
fi
exit 0
