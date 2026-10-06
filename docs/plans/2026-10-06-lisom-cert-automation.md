# lisom.work 证书自动化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 lisom.work 证书续期的「通知 / 监控 / 交付」三段自动化,使 90 天周期最多剩 2 分钟人工(natcross 上架两个映射),且任何失败都会在到期前 15 天告警。

**Architecture:** 三个独立小脚本(`cert-notify.sh` / `cert-monitor.sh` / `cert-deliver.sh`)放在 appnet 仓库 `scripts/`,由 bio 的 cron 与 acme.sh 的 reloadcmd 钩子驱动;所有敏感值放**仓库外** `~/manage/secrets/lisom.env`(600)。

**Tech Stack:** bash(辅以 python3 / jq)、openssl、dig、acme.sh(已装于 `~/.acme.sh`)、cron。

**Spec:** `docs/specs/2026-10-06-lisom-cert-automation-design.md`

> 实现演进说明:本计划的代码块为设计时版本,**以仓库 `scripts/` 下实现为准**(实现已迭代:private.key 命名、飞书签名校验通道、评审修复)。

## Global Constraints

- 仓库(远端 GitHub `WangLabCSU/appnet`)内**任何文件不得包含** token / webhook URL / 私钥(spec §8);敏感值只在 `~/.acme.sh/account.conf` 与 `~/manage/secrets/lisom.env`(600)。
- 脚本以 bio 用户运行;不引入新依赖(lab-bio 已核实:timeout / python3 / jq / dig / getent 可用;无 shellcheck,跳过)。
- 日志写 `logs/`(已 gitignore);本计划的提交只到**本地**,不执行 `git push`。
- 通知未配置 webhook 时**降级为仅写日志**,不得报错、不得中断调用链。
- natcross 边缘证书保存后**异步生效 1–5 分钟**(spec §5),任何"刚上架即断言"的检查必须容忍该延迟。
- 脚本风格对齐仓库既有脚本(见 `scripts/check-apps.sh`):`#!/usr/bin/env bash`、`set -u`、`SCRIPT_DIR/BASE_DIR` 推导、中文注释。

## Review Focus

1. **凭据泄漏**——脚本、日志、提交中不得出现 token / webhook URL;通知消息只允许含域名、指纹、时间。
2. **异步生效误判**——上架后 1–5 分钟内指纹比对可能仍不相等;monitor 为每日运行天然容忍,人工演练时须等待后再判读(Task 4 已内置等待步骤)。
3. **边缘 IP / DNS 漂移**——natcross 若迁移节点,硬编码 IP 会永久误报;monitor 每次运行都重新解析当前 A 记录。
4. **边缘不可达时挂死**——openssl 连接必须被 `timeout` 包裹,避免 cron 卡死;单次失败也告警(每日一条,不构成骚扰)。
5. **reloadcmd 失败静默**——续期成功但交付失败时若不告警,用户会误以为一切正常;deliver 的每个失败分支都必须走通知。

---

### Task 1: cert-notify.sh — 通知底座(企业微信 + 日志降级)

**Files:**
- Create: `scripts/cert-notify.sh`(仓库)
- Create: `~/manage/secrets/lisom.env`(600,仓库外;含空模板)

**Interfaces:**
- Produces: `cert-notify.sh "<消息>"` → 追加 `logs/cert.log` 一行;若 `WECOM_WEBHOOK` 已配置则同时推送企业微信;无配置或发送失败时**仍 exit 0**(仅记录)。`NOTIFY_DRY_RUN=1` 时只打印将发送的 JSON,不实际请求。
- 后续所有脚本只用这一条通知出路。

- [ ] **Step 1: 创建 secrets 目录与空模板**

```bash
mkdir -p ~/manage/secrets && chmod 700 ~/manage/secrets
cat > ~/manage/secrets/lisom.env <<'EOF'
# lisom 证书自动化敏感配置(0600,严禁入仓库,见 docs/specs/2026-10-06-lisom-cert-automation-design.md §8)
# 企业微信群机器人 webhook
WECOM_WEBHOOK=""
# 飞书自定义机器人 webhook(启用「签名校验」时另填 secret)
FEISHU_WEBHOOK=""
FEISHU_SECRET=""
# 可选:Mac 推送目标(需 Mac 开启 sshd),如 wsx@100.x.y.z;留空则不推送
DELIVER_MAC=""
EOF
chmod 600 ~/manage/secrets/lisom.env
```

- [ ] **Step 2: 写脚本(完整代码)**

```bash
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
```

- [ ] **Step 3: 测试 — 日志路径(未配置 webhook)**

Run: `scripts/cert-notify.sh "测试消息 $(date +%s)"`;`echo $?`;`tail -2 logs/cert.log`
Expected: exit 0;stderr 一行"未配置 WECOM_WEBHOOK";日志出现该消息。

- [ ] **Step 4: 测试 — webhook 请求构造(dry-run)**

Run:
```bash
cp ~/manage/secrets/lisom.env /tmp/lisom.env.bak
sed -i 's|^WECOM_WEBHOOK=.*|WECOM_WEBHOOK="https://example.com/dummy"|' ~/manage/secrets/lisom.env
NOTIFY_DRY_RUN=1 scripts/cert-notify.sh "测试"
cp /tmp/lisom.env.bak ~/manage/secrets/lisom.env && rm /tmp/lisom.env.bak
```
Expected: 打印 `{"msgtype":"text",...}` 的 JSON,不发起真实请求;结束后 secrets 文件已还原为原内容。
(用户提供真实 webhook URL 后:填入 secrets 文件,再执行一次不带 dry-run 的调用,微信应收到消息——不阻塞后续任务。)

- [ ] **Step 5: 提交**

```bash
git add scripts/cert-notify.sh
git commit -m "feat(cert): 证书通知脚本(企业微信机器人 + 日志降级)"
```

---

### Task 2: cert-monitor.sh — 每日监控(指纹比对 + 到期检查)

**Files:**
- Create: `scripts/cert-monitor.sh`
- Modify: bio crontab(追加一行)

**Interfaces:**
- Consumes: `scripts/cert-notify.sh "…"`(Task 1)
- Produces: 退出码 0=全部正常 / 1=有告警;成功时只写日志(周一额外发一条心跳),告警时经 cert-notify 推送;参数 `--threshold-days N`(默认 15)与 `--local-fp <hex>`(测试用,模拟"已续签未上架")。

- [ ] **Step 1: 写脚本(完整代码)**

```bash
#!/usr/bin/env bash
# cert-monitor — lisom.work 证书监控(每日 cron)
# 检查两件事:
#   1) 边缘(natcross)实际下发的证书指纹 == 本地 acme.sh 最新签发指纹?
#      不等 = "已续签未上架"(上架后边缘异步生效需 1–5 分钟,日检天然容忍)
#   2) 本地证书剩余天数 < 阈值(默认 15)→ 告警
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
for h in "${HOSTS[@]}"; do
    ip="$(dig +short "$h" A @223.5.5.5 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)"
    if [ -z "$ip" ]; then alerts="${alerts}[$h] DNS 解析失败; "; continue; fi
    ef="$(edge_fp "$h" "$ip")"
    if [ -z "$ef" ]; then
        alerts="${alerts}[$h] 边缘($ip)连接或证书读取失败; "
    elif [ "$ef" != "$lf" ]; then
        alerts="${alerts}[$h] 边缘证书与本地最新签发不一致(可能已续签未上架); "
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

echo "[$ts] OK: 两域名边缘指纹一致,本地证书剩 ${dl} 天" >> "$LOG_FILE"
if [ "$(date +%u)" = "1" ]; then   # 每日心跳,防"监控静默死亡"
    "$NOTIFY" "✅ lisom 证书监控正常(本地证书剩 ${dl} 天)"
fi
exit 0
```

- [ ] **Step 2: 测试 — 正常路径(green)**

Run: `chmod +x scripts/cert-monitor.sh && scripts/cert-monitor.sh; echo "exit=$?"`
Expected: `exit=0`;`tail -1 logs/cert.log` 含 `OK: 两域名边缘指纹一致`。

- [ ] **Step 3: 测试 — 未上架告警路径(red)**

Run: `scripts/cert-monitor.sh --local-fp 0000000000000000000000000000000000000000000000000000000000000000; echo "exit=$?"`
Expected: `exit=1`;日志含 `ALERT` 与 `不一致`;dry-run(`NOTIFY_DRY_RUN=1`)下可看到告警 JSON。

- [ ] **Step 4: 测试 — 到期阈值路径(red)**

Run: `scripts/cert-monitor.sh --threshold-days 999; echo "exit=$?"`
Expected: `exit=1`;告警含 `仅剩`。

- [ ] **Step 5: 安装 cron(幂等,防重复行)**

```bash
( crontab -l 2>/dev/null | grep -v "cert-monitor" ; \
  echo '7 8 * * * umask 027; /home/bio/manage/appnet/scripts/cert-monitor.sh >> /home/bio/manage/appnet/logs/cert-cron.log 2>&1' ) | crontab -
crontab -l | grep cert-monitor
```
Expected: 输出恰一行 cron;再次执行不会重复(先 grep -v 再追加)。

- [ ] **Step 6: 提交**

```bash
git add scripts/cert-monitor.sh
git commit -m "feat(cert): 每日证书监控(边缘指纹比对 + 到期阈值 + 每日心跳)"
```

---

### Task 3: cert-deliver.sh + acme.sh 钩子 — 续期自动交付

**Files:**
- Create: `scripts/cert-deliver.sh`
- Create: `~/manage/lisom-cert/`(700,仓库外;deploy 落盘目录)
- Modify: acme.sh 证书配置(`--install-cert` 写入 `Le_ReloadCmd` 等)
- Modify: `docs/specs/2026-10-06-lisom-cert-automation-design.md` §4(补"取件"步骤)

**Interfaces:**
- Consumes: acme.sh 续期钩子;`~/manage/lisom-cert/{fullchain.pem,private.key}`(由 `--install-cert` 负责落盘与更新)
- Produces: `cert-deliver.sh`(无参数)→ 校验配对 → 通知"新证书已签发 + 上架指引";任一失败分支发告警。可选 `DELIVER_MAC` 推送(默认关)。

- [ ] **Step 1: 写脚本(完整代码)**

```bash
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
key="$DEPLOY_DIR/private.key"

[ -f "$cert" ] && [ -f "$key" ] || { "$NOTIFY" "❌ lisom 证书交付:deploy 文件缺失($DEPLOY_DIR),请检查 acme.sh --install-cert 配置"; exit 1; }

h1="$(openssl x509 -in "$cert" -noout -pubkey | openssl sha256)"
h2="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256)"
[ "$h1" = "$h2" ] || { "$NOTIFY" "❌ lisom 证书交付:fullchain 与 privkey 不配对,禁止上架"; exit 1; }

fp="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | sed 's/^.*=//')"
exp="$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)"

"$NOTIFY" "🔔 lisom 新证书已签发(至 ${exp},指纹 ${fp:0:17}…)。上架步骤:① 取件: scp lab-bio:~/manage/lisom-cert/fullchain.pem lab-bio:~/manage/lisom-cert/private.key ~/Downloads/ ② natcross 两个映射(lisom.work / csu.lisom.work)分别贴 pem/key 并保存 ③ 等 1–5 分钟后执行 scripts/cert-monitor.sh 自检"

DELIVER_MAC=""
[ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"
if [ -n "${DELIVER_MAC:-}" ]; then
    if ! timeout 30 scp -q -o ConnectTimeout=10 -o BatchMode=yes "$cert" "$key" "${DELIVER_MAC}:" 2>/dev/null; then
        "$NOTIFY" "⚠️ lisom 证书交付:向 ${DELIVER_MAC} 推送失败(不影响上架,可手动取件)"
    fi
fi
exit 0
```

- [ ] **Step 2: 部署目录 + acme.sh 钩子安装**

```bash
mkdir -p ~/manage/lisom-cert && chmod 700 ~/manage/lisom-cert
~/.acme.sh/acme.sh --install-cert -d lisom.work \
    --key-file   "$HOME/manage/lisom-cert/private.key" \
    --fullchain-file "$HOME/manage/lisom-cert/fullchain.pem" \
    --reloadcmd  "$HOME/manage/appnet/scripts/cert-deliver.sh"
grep -E "Le_(ReloadCmd|RealCertPath|RealKeyPath)" ~/.acme.sh/lisom.work/lisom.work.conf
```
Expected: `--install-cert` 输出成功;conf 中出现三项;`ls -l ~/manage/lisom-cert/` 有 `fullchain.pem` 与 `private.key`(privkey 权限应为 600,若否 `chmod 600`)。
(注:`--install-cert` 会**立即执行一次** reloadcmd,因此会马上看到一条「🔔 新证书已签发」日志/通知——此时证书尚未变化,属安装触发的正常现象,忽略即可;Task 4 演练时才是真实触发。)

- [ ] **Step 3: 测试 — 手工运行交付**

Run: `NOTIFY_DRY_RUN=1 scripts/cert-deliver.sh; echo "exit=$?"`
Expected: exit 0;dry-run 打印含"新证书已签发"与取件命令的通知 JSON;无"❌"。

- [ ] **Step 4: 测试 — 坏配对分支(red)**

Run:
```bash
mv ~/manage/lisom-cert/private.key /tmp/pk.bak && echo "bad" > ~/manage/lisom-cert/private.key
NOTIFY_DRY_RUN=1 scripts/cert-deliver.sh; echo "exit=$?"
mv /tmp/pk.bak ~/manage/lisom-cert/private.key
```
Expected: exit 1,通知含"不配对";恢复后重跑 Step 3 应再次通过。

- [ ] **Step 5: 更新 spec §4 运行手册**(补取件步骤与 deploy 目录说明),提交:

```bash
git add scripts/cert-deliver.sh docs/specs/2026-10-06-lisom-cert-automation-design.md
git commit -m "feat(cert): 续期自动交付脚本 + acme.sh reloadcmd 钩子"
```

---

### Task 4: 全链路演练(需用户参与,约 15 分钟)

**Interfaces:**
- Consumes: Task 1–3 全部产物;用户执行 natcross 上架(两个映射)
- Produces: spec §5 追加演练记录;确认三个脚本 + cron + 钩子真实联动

- [ ] **Step 1: 强制重签(触发完整链路)**

Run: `~/.acme.sh/acme.sh --renew --force -d lisom.work -d '*.lisom.work'`
Expected: 签发成功;随后 reloadcmd 自动运行 → 收到(或 dry-run 日志出现)"🔔 新证书已签发"。
(注:Let's Encrypt 限额为每域名集 5 次/周,本演练消耗 1 次,无碍。)

- [ ] **Step 2: 验证监控能抓"未上架"**

Run: `scripts/cert-monitor.sh; echo "exit=$?"`
Expected: **exit=1**,告警"边缘证书与本地最新签发不一致"——此时边缘还是上一张证书,属预期,证明监控有效。

- [ ] **Step 3: 用户上架(人工,~2 分钟)**

用户按通知里的取件命令取两个文件 → natcross 两个映射各贴 pem/key → 保存。

- [ ] **Step 4: 等待并复检**

等 3–5 分钟(异步生效),Run: `scripts/cert-monitor.sh; echo "exit=$?"`
Expected: **exit=0**,`OK: 两域名边缘指纹一致`。

- [ ] **Step 5: 外部复核**

Run: `echo | openssl s_client -connect 47.238.204.197:443 -servername lisom.work 2>/dev/null | openssl x509 -noout -dates -fingerprint -sha256`
Expected: 指纹 == `~/.acme.sh/lisom.work/fullchain.cer` 的指纹(与演练前不同,即新的一张)。

- [ ] **Step 6: 记录并提交**

spec §5 追加演练结果(日期、新指纹、通过项),`git commit -m "docs(cert): 全链路演练记录"`。

---

### Task 5: B1 可行性验证(可选,需用户抓一次 HAR)

**Files:**
- Modify: `docs/specs/2026-10-06-lisom-cert-automation-design.md` §7(写入结论)

- [ ] **Step 1: 用户抓包**

用户在 Mac 上:Chrome 打开 natcross 控制台 → F12 → Network → 勾选 Preserve log → 对 lisom.work 映射**重复上传当前同一套证书**(幂等,无副作用)→ 保存 → 右键导出 HAR 交给实施者。

- [ ] **Step 2: 分析 HAR**

识别:①登录/鉴权方式(会话 cookie?token?)②上传请求 URL、方法、字段名、两个映射的标识 ③是否有 CSRF/验证码。结论二选一:

- **可行** → 记录接口清单到 spec §7,后续另立计划实现 `cert-upload.sh`(本计划不实现)
- **不可行**(验证码/强风控等)→ spec §7 记录结论,长期维持 B2(每 90 天 2 分钟)

- [ ] **Step 3: 提交结论**

```bash
git add docs/specs/2026-10-06-lisom-cert-automation-design.md
git commit -m "docs(cert): B1 可行性结论"
```

---

## Self-Review 记录

- **Spec 覆盖**:§2.1 已完成(桥,不在本计划);§2.2 B2 改进 → Task 1+3;§2.3 B1 → Task 5(验证与决策,符合 spec"先验证再决定");§2.4 监控 → Task 2(+Task 1 通知);§4 运行手册 → Task 3 Step 5、Task 4;§7 开放项 → Task 2/3/5 逐项闭环。
- **占位符扫描**:所有代码步骤含完整代码;所有测试步骤含具体命令与预期输出;"用户提供 webhook"处已给出 dry-run 替代路径,不阻塞。
- **类型/命名一致性**:`cert-notify.sh`/`cert-monitor.sh`/`cert-deliver.sh` 三脚本命名与调用关系在 Task 1 定义、Task 2/3 引用保持一致;`logs/cert.log` 为统一日志名;`~/manage/lisom-cert/` 为统一 deploy 目录;`WECOM_WEBHOOK`/`DELIVER_MAC` 变量名一致。
- **Review Focus 对应测试**:①凭据→各脚本注释+提交自查步骤;②异步→Task 4 Step 4 等待;③IP 漂移→Task 2 代码内 dig 解析;④超时→Task 2 代码内 timeout 包裹;⑤交付失败→Task 3 Step 4 坏配对测试。
