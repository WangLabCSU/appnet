#!/usr/bin/env bash
# cert-notify — 证书自动化统一通知出口
# 用法: cert-notify.sh "消息内容"
# 行为: 始终追加 logs/cert.log;按优先级选择推送通道:
#       ① FEISHU_WEBHOOK(飞书自定义机器人;若启用「签名校验」,另在 secrets 配 FEISHU_SECRET)
#       ② WECOM_WEBHOOK(企业微信群机器人)
#       都未配置 = 仅记日志(不报错)。
# 判定: 用 jq 结构化解析响应(code/errcode == 0 才算成功),避免子串误判。
# 安全: 本文件不得出现任何凭据;secret 经环境变量传入,不落 argv;消息不得含 token/webhook。
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
FEISHU_SECRET=""
WECOM_WEBHOOK=""
[ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"

# 选择通道,构造对应格式的 payload(飞书与企微 JSON 结构不同)
channel=""
url=""
payload=""
if [ -n "${FEISHU_WEBHOOK:-}" ]; then
    channel="feishu"
    url="$FEISHU_WEBHOOK"
    if [ -n "${FEISHU_SECRET:-}" ]; then
        # 飞书「签名校验」:sign = base64(HMAC-SHA256(key="<timestamp>\n<secret>", msg=""))
        payload="$(f_msg="$msg" f_secret="$FEISHU_SECRET" python3 -c '
import base64, hashlib, hmac, json, os, time
ts = str(int(time.time()))
key = (ts + "\n" + os.environ["f_secret"]).encode("utf-8")
sign = base64.b64encode(hmac.new(key, digestmod=hashlib.sha256).digest()).decode()
print(json.dumps({"timestamp": ts, "sign": sign, "msg_type": "text",
                  "content": {"text": os.environ["f_msg"]}}, ensure_ascii=False))
')"
    else
        payload="$(python3 -c 'import json,sys; print(json.dumps({"msg_type":"text","content":{"text":sys.argv[1]}}, ensure_ascii=False))' "$msg")"
    fi
elif [ -n "${WECOM_WEBHOOK:-}" ]; then
    channel="wecom"
    url="$WECOM_WEBHOOK"
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
# 成功判定:飞书 {"code":0,…} / 企微 {"errcode":0,…};结构化解析,拒绝子串误判
if ! printf '%s' "$resp" | jq -e 'if has("code") then .code == 0 else .errcode == 0 end' >/dev/null 2>&1; then
    clean="$(printf '%s' "$resp" | tr -d '\n\r' | cut -c1-160)"
    echo "[$ts] 通知发送失败(channel=${channel}): ${clean}" >> "$LOG_FILE"
fi
exit 0
