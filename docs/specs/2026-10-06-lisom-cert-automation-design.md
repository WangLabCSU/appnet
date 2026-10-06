# lisom.work 证书自动化设计

- 日期:2026-10-06
- 状态:**签发端已上线 ✅**;上架端 = 半自动(B2,现行);全自动(B1)与监控 = 待实施
- 相关主机:lab-bio(bio 用户)、natcross 边缘(47.238.204.197)
- 域名:lisom.work、csu.lisom.work(两个 natcross 映射,共用 `*.lisom.work` 证书)

## 1. 背景与目标

对外链路:

```
互联网 → natcross 边缘 (47.238.204.197, nginx, TLS 在此终结)
       → KCP 隧道 :9005 → lab-bio 的 natcross_client
       → Caddy :8880 (纯 HTTP) → landing / gitea / rstudio / shiny 等
```

证书必须上传到 natcross 控制台「修改映射」页的 pem / key 两个框。
原流程每 90 天全手动:申请证书 → 手动加 DNS TXT → 下载 → 两个映射各上传一次。

目标:

1. 签发零人工(DNS-01 全自动)
2. 上架最简(2 分钟)或全自动
3. 任何环节失败都不会静默到期(监控兜底)

## 2. 方案

### 2.1 签发端(已上线,2026-10-06)

| 项 | 值 |
|---|---|
| 工具 | acme.sh,用户级安装于 lab-bio `~/.acme.sh`(bio 用户,无需 sudo) |
| CA | Let's Encrypt |
| 证书 | `lisom.work + *.lisom.work`,RSA 2048 |
| 验证 | DNS-01,经 DNSPod API(`--dns dns_dp`) |
| 凭据 | `DP_Id` / `DP_Key` 存于 `~/.acme.sh/account.conf`(权限 600) |
| 自动续期 | acme.sh 自带 cron(每日检查,按 ARI 窗口重签;下次窗口 ≈ 2026-12-05) |
| 产物 | `~/.acme.sh/lisom.work/fullchain.cer`、`lisom.work.key` |

⚠️ **该 DNSPod token 已服务于自动续期,不可删除/重置**。如确需轮换凭据:更新 `account.conf` 后
执行 `~/.acme.sh/acme.sh --renew --force -d lisom.work -d '*.lisom.work'` 验证,再重新上传。

### 2.2 上架端 B2(半自动,现行)

每次续期后,把 `fullchain.cer` 与 `lisom.work.key` 分别贴入**两个映射**(lisom.work、csu.lisom.work)
的 pem / key 框并保存。注意:

- natcross 保存后**异步生效,约 1–5 分钟**(2026-10-06 实测)
- 上传后必须自检(命令见 §4),指纹应与 `~/.acme.sh/lisom.work/fullchain.cer` 一致

改进(待实施):给 acme.sh 加 `--reloadcmd` 钩子 → 调用 `scripts/cert-deliver.sh`:

1. 记录日志
2. 通知「新证书已签发,请上架」
3. 自动把两个文件送达 Mac 并校验公私钥配对

### 2.3 上架端 B1(全自动,二期,可行性待验证)

思路:脚本模拟 natcross 控制台上传(登录 → 对两个映射分别提交 pem / key)。
前提:人工做一次上传时用浏览器 F12 抓 HAR,确认内部接口与鉴权方式(登录态、CSRF)。
风险:非公开接口,对方改版即失效 → **必须在 §2.4 监控就绪后才可启用**;失效会以告警暴露。
若不可行:长期保持 B2(每 90 天 2 分钟)+ 监控。

### 2.4 监控与通知(待实施)

`scripts/cert-monitor.sh`(lab-bio cron,每日):

1. 取边缘证书指纹:`openssl s_client` 分别对 lisom.work 与 csu.lisom.work 两个 SNI(防单个映射漏传)
2. 与本地最新签发指纹比对 → 不一致 ⇒ 「已续签但未上架」告警
3. 距到期 < 15 天 ⇒ 「即将到期」告警

通知:`scripts/notify.sh`,默认企业微信群机器人 webhook(URL 存 lab-bio 本地,可替换为邮件等)。
监控是 B1 敢启用的前提,也是 B2 模式下的保险丝。

## 3. 组件与文件

| 位置 | 内容 |
|---|---|
| lab-bio `~/.acme.sh/` | acme.sh、证书、DNSPod 凭据、续期 cron(已就位) |
| lab-bio `~/manage/appnet/scripts/cert-*.sh` | cert-deliver.sh、cert-monitor.sh、notify.sh(待实施) |
| natcross 控制台 | 两个映射的 pem / key 上传框(人工维护) |
| Mac `~/Downloads/lisom-cert-<date>/` | 交付副本(2026-10-06 首份位于 `lisom-cert-2026-10/`) |

## 4. 运行手册

- **常规循环(约 90 天)**:收到「新证书待上架」→ natcross 控制台 → 映射 lisom.work 贴 pem / key →
  保存 → 映射 csu.lisom.work 同操作 → 等 1–5 分钟 → 自检
- **自检命令**:

  ```bash
  echo | openssl s_client -connect 47.238.204.197:443 -servername lisom.work 2>/dev/null \
    | openssl x509 -noout -dates -fingerprint -sha256
  # 与本地比对:
  openssl x509 -in ~/.acme.sh/lisom.work/fullchain.cer -noout -fingerprint -sha256
  ```

- **强制重签**:`~/.acme.sh/acme.sh --renew --force -d lisom.work -d '*.lisom.work'`
- **应急备胎**:acmessl(natcross 同公司)的 certapi 实测可用
  (签名 = MD5(email + apiKey + rand + timestamp));但其服务端 DNS 验证不可靠,
  仅在 Let's Encrypt 被限流等场景作为备份签发通道。

- **续期后取件(2026-10-06 增补)**:新证书自动落盘至 `~/manage/lisom-cert/{fullchain.pem,privkey.pem}`
  (由 `acme.sh --install-cert` 维护,位于仓库外);Mac 上执行:
  `scp lab-bio:~/manage/lisom-cert/fullchain.pem lab-bio:~/manage/lisom-cert/privkey.pem ~/Downloads/`
  两个文件分别贴入 natcross 两个映射的 pem / key 框。

## 5. 验证记录

- 2026-10-06 17:21 首次自动签发成功(Let's Encrypt;指纹 `2B:96:C7:41:…:28:BD:53`;2027-01-04 到期)
- 2026-10-06 17:35 手工上架两个映射 → 外部验证:两个 SNI 均为新指纹,
  `https://lisom.work` 与 `https://csu.lisom.work` 均 HTTP 200、TLS 校验通过
- 备忘:natcross 另有 134.175.80.187 / 121.43.123.6 两个节点,对 SNI lisom.work 返回其自有品牌
  默认证书(`*.newnet.vip` / `*.gbfweg.top`),与本域名无关(公网 A 记录只指向 47.238.204.197)

## 6. 决策记录

- 弃用 acmessl 自动链路:其服务端连不上 DNSPod,且平台不可控(已故障一次)
- 弃用 TLS 透传:natcross 映射协议为 HTTP、TLS 在边缘终结,无透传选项
- 签发端放 lab-bio:常开机、与隧道客户端同机、出网可达 LE 与 DNSPod(均已实测)
- 桥接证书选 Let's Encrypt + RSA:与现行证书类型一致,兼容性零风险

## 7. 开放项

- [ ] B1 可行性验证(抓一次上传 HAR)
- [ ] 通知通道最终选型(默认企业微信群机器人)
- [ ] cert-monitor.sh / cert-deliver.sh 实施

## 8. 安全约束(长期有效)

本仓库远端为 GitHub(`WangLabCSU/appnet`),以下约束长期有效:

- **仓库内任何文件不得包含**:DNSPod token、acmessl API key、通知 webhook URL、私钥内容
- 敏感值统一放仓库外:
  - acme.sh 凭据:`~/.acme.sh/account.conf`(600,已在使用)
  - 后续脚本的敏感配置:`~/manage/secrets/lisom.env`(600,不入库),脚本只引用变量名
- `.gitignore` 已加入 `*.key`、`*.pem`、`secrets*.env` 防御性规则
- 私钥副本(如 Mac `~/Downloads/lisom-cert-*/private.key`)用完即删;lab-bio 上的私钥位于
  `~/.acme.sh`(600 权限)
- 提交前自查:`git diff --cached` 过一遍,确认无凭据
