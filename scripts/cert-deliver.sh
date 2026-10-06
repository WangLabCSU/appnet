#!/usr/bin/env bash
# cert-deliver — acme.sh reloadcmd 钩子:续期完成后的交付与提醒
# 触发: acme.sh 每次成功续期后自动调用;也可手工运行。
# 动作: 1) 校验 deploy 目录 fullchain 与 privkey 配对
#       2) 通知"新证书已就绪"+上架指引;失败则告警
# 说明: 默认不向 Mac 推送(依赖 Mac 端 sshd,不稳定);通知内附取件命令。
#       如 secrets 中配置了 DELIVER_MAC(如 wsx@100.x.y.z),额外尝试 scp,失败仅告警。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="$SCRIPT_DIR/cert-notify.sh"
DEPLOY_DIR="$HOME/manage/lisom-cert"
SECRETS_FILE="$HOME/manage/secrets/lisom.env"
cert="$DEPLOY_DIR/fullchain.pem"
key="$DEPLOY_DIR/privkey.pem"

[ -f "$cert" ] && [ -f "$key" ] || { "$NOTIFY" "❌ lisom 证书交付:deploy 文件缺失($DEPLOY_DIR),请检查 acme.sh --install-cert 配置"; exit 1; }

h1="$(openssl x509 -in "$cert" -noout -pubkey | openssl sha256)"
h2="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256)"
[ "$h1" = "$h2" ] || { "$NOTIFY" "❌ lisom 证书交付:fullchain 与 privkey 不配对,禁止上架"; exit 1; }

fp="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | sed 's/^.*=//')"
exp="$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)"

"$NOTIFY" "🔔 lisom 新证书已签发(至 ${exp},指纹 ${fp:0:17}…)。上架步骤:① 取件: scp lab-bio:~/manage/lisom-cert/fullchain.pem lab-bio:~/manage/lisom-cert/privkey.pem ~/Downloads/ ② natcross 两个映射(lisom.work / csu.lisom.work)分别贴 pem/key 并保存 ③ 等 1–5 分钟后执行 scripts/cert-monitor.sh 自检"

DELIVER_MAC=""
[ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"
if [ -n "${DELIVER_MAC:-}" ]; then
    if ! timeout 30 scp -q -o ConnectTimeout=10 -o BatchMode=yes "$cert" "$key" "${DELIVER_MAC}:" 2>/dev/null; then
        "$NOTIFY" "⚠️ lisom 证书交付:向 ${DELIVER_MAC} 推送失败(不影响上架,可手动取件)"
    fi
fi
exit 0
