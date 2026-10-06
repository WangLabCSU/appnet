#!/usr/bin/env bash
# cert-notify — 证书自动化统一通知出口
# 用法: cert-notify.sh "消息内容"
# 行为: 始终追加 logs/cert.log;按优先级选择推送通道:
#       ① FEISHU_WEBHOOK(飞书自定义机器人;建议安全设置用「自定义关键词」= lisom)
#       ② WECOM_WEBHOOK(企业微信群机器人)
#       都未配置 = 仅记日志(不报错)。
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

FEISHU_WEBHOOK=""
WECOM_WEBHOOK=""
[ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"

# 选择通道,构造对应格式的 payload(飞书与企微 JSON 结构不同)
channel=""
url=""
payload=""
ok_marker=""
if [ -n "${FEISHU_WEBHOOK:-}" ]; then
    channel="feishu"
    url="$FEISHU_WEBHOOK"
    ok_marker='"code":0'
    payload="$(python3 -c 'import json,sys; print(json.dumps({"msg_type":"text","content":{"text":sys.argv[1]}}, ensure_ascii=False))' "$msg")"
elif [ -n "${WECOM_WEBHOOK:-}" ]; then
    channel="wecom"
    url="$WECOM_WEBHOOK"
    ok_marker='"errcode":0'
    payload="$(python3 -c 'import json,sys; print(json.dumps({"msgtype":"text","text":{"content":sys.argv[1]}}, ensure_ascii=False))' "$msg")"
fi

if [ -z "$url" ]; then
    echo "[cert-notify] 未配置任何 webhook(FEISHU_WEBHOOK / WECOM_WEBHOOK),仅记录日志" >&2
    exit 0
fi

if [ "${NOTIFY_DRY_RUN:-0}" = "1" ]; then
    echo "[cert-notify][dry-run] channel=${channel} payload=${payload}"
    exit 0
fi

resp="$(timeout 15 curl -s -m 15 -X POST -H 'Content-Type: application/json' -d "$payload" "$url" 2>/dev/null || true)"
if ! echo "$resp" | grep -q "$ok_marker"; then
    echo "[$ts] 通知发送失败(channel=${channel}): ${resp:0:160}" >> "$LOG_FILE"
fi
exit 0
