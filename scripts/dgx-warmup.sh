#!/bin/bash
# dgx-warmup — 实验室 DGX 网关（labapi）首请求预热
#
# 为什么存在
#   Claude Code / Codex 等客户端的**首请求**载荷很大（约 1.8 万 token 的
#   system + tools），vLLM prefix cache 未命中时这次 prefill 要 5–6 秒，
#   表现为「首次连接特别慢」。vLLM 的 prefix cache 是 LRU，长时间没有
#   同前缀的流量就会逐出——所以用定时任务周期性重放。
#
# 怎么工作
#   遍历 warmup-payloads/ 下的 *.json（**每个客户端家族一份真实首请求**，
#   从抓包导出、max_tokens 已改 1），逐个以 stream 模式 POST 到
#   labapi/v1/messages。**必须字节级同前缀**才有命中：prefix cache 只从
#   token 0 起按块匹配，小探针热不了大载荷；不同工具/版本的前缀不同，
#   Claude Code 各版本共享稳定头部可部分覆盖，其他工具要各自抓包补文件。
#
# ⚠️ 模型名用主名 qwen3.8-flash-next（与真实流量同渲染）；别换成
#    -nothink——网关对它注入不同的 chat_template_kwargs，渲染出的
#    prompt 不同，预热无效。
#
# 凭据：config/dgx-warmup.env（0600，已 gitignore），token 由管理员从
#   各自 ~/.local/bin/ccm 取，**绝不写进本仓库**。
#
# cron（bio 用户，10 分钟一次）：
#   */10 * * * * /home/bio/manage/appnet/scripts/dgx-warmup.sh >> \
#     /home/bio/manage/appnet/logs/dgx-warmup-cron.log 2>&1

set -u
umask 077

APPNET_DIR="/home/bio/manage/appnet"
PAYLOAD_DIR="$APPNET_DIR/warmup-payloads"
ENV_FILE="$APPNET_DIR/config/dgx-warmup.env"
LOG_FILE="$APPNET_DIR/logs/dgx-warmup.log"
LOCK_FILE="$APPNET_DIR/logs/dgx-warmup.lock"

# 上游与模型。URL 用公网隧道入口（与真实客户端同路径，网关与 Caddy
# 都能被顺带保温）；max_tokens=1 只为刷 LRU 时钟，不产出内容。
URL="http://biotree.top:38123/labapi/v1/messages"
MODEL="qwen3.8-flash-next"
CURL_TIMEOUT=90

# 单实例：10 分钟一次的 cron 不该叠跑（上一轮没跑完时本轮直接退出）
mkdir -p "$APPNET_DIR/logs"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] skip: 上一轮还在跑" >> "$LOG_FILE"
    exit 0
fi

# token 从 0600 env 文件读，不进仓库
if [ ! -r "$ENV_FILE" ]; then
    echo "[$(date '+%F %T')] ERROR: 缺 $ENV_FILE（含 DGX_WARMUP_TOKEN），先创建它" >> "$LOG_FILE"
    exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
if [ -z "${DGX_WARMUP_TOKEN:-}" ]; then
    echo "[$(date '+%F %T')] ERROR: $ENV_FILE 未定义 DGX_WARMUP_TOKEN" >> "$LOG_FILE"
    exit 1
fi

shopt -s nullglob
payloads=("$PAYLOAD_DIR"/*.json)
if [ ${#payloads[@]} -eq 0 ]; then
    echo "[$(date '+%F %T')] WARN: $PAYLOAD_DIR 下无载荷，跳过" >> "$LOG_FILE"
    exit 0
fi

echo "[$(date '+%F %T')] start: ${#payloads[@]} 个载荷" >> "$LOG_FILE"
for pf in "${payloads[@]}"; do
    name=$(basename "$pf" .json)
    # TTFT 取流式首字节；总耗时取整次请求。都不打印体与头，避免泄凭据。
    ttff=$(curl -s -o /dev/null -X POST "$URL" \
        -H "authorization: Bearer $DGX_WARMUP_TOKEN" \
        -H 'content-type: application/json' \
        --data-binary @"$pf" \
        --max-time "$CURL_TIMEOUT" \
        -w '%{http_code} %{time_starttransfer} %{time_total}')
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "[$(date '+%F %T')]   $name: curl 失败 rc=$rc" >> "$LOG_FILE"
        continue
    fi
    code=${ttff%% *}
    rest=${ttff#* }
    echo "[$(date '+%F %T')]   $name: http=$code ttff=${rest% *} total=${rest#* }" >> "$LOG_FILE"
done
echo "[$(date '+%F %T')] done" >> "$LOG_FILE"
