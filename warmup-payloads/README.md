# warmup-payloads — labapi 首请求预热载荷

本目录存放「按客户端家族」抓取的**真实首请求载荷**，由
`scripts/dgx-warmup.sh`（cron 每 10 分钟）重放，用于保持 vLLM prefix
cache 温热，把新会话首字延迟从 ~6 s 压到 ~2 s。

## 为什么每个客户端家族要一份载荷

vLLM 的 prefix cache **只从 token 0 起按块匹配**：system + tools +
第一条 user 消息的任何一处不同，都整段失效。所以：

- 同一版本 Claude Code 的团队成员**共享一份**（实测他人会话命中，TTFT 2.2 s）
- 不同版本 / 不同工具（Codex 等）前缀不同，**各自抓包补一份文件**
- 小探针（"hi" 之类）热不了大载荷，别指望通用载荷

文件名约定：`<客户端>-<版本>.json`，脚本遍历 `*.json` 全部重放。
文件名带 `.responses`（如 `codex-cli-0.152.0.responses.json`）走
OpenAI Responses API（`/v1/responses`），其余默认走 Anthropic
Messages API（`/v1/messages`）。

## 怎么抓一个新家族（5 步）

前提：装了 python3 的任意机器能直连 `biotree.top:38123`。

1. **起抓包代理**（端口自选，如 8123）：

       python3 scripts/logging-proxy.py 8123 biotree.top 38123 > /tmp/cap.log 2>&1 &

   `logging-proxy.py` 若本机没有，从 dgx-portal 仓库 docs/clients.md §7
   处的自包含版本复制。日志含 **authorization / x-api-key 明文凭据**：
   文件默认 0600，**排查完立刻 `rm`，绝不贴到公开地方**。

2. **让目标客户端走代理发一条真实消息**。以 Claude Code 为例：

       ANTHROPIC_BASE_URL=http://127.0.0.1:8123 \
       ANTHROPIC_AUTH_TOKEN=<ccm 里的 labapi token> \
       claude -p "回复 ok 即可" --model qwen3.8-flash-next --max-turns 1

   （其他工具同理：把 base_url 指到代理，发一条最短真实消息。）

3. **从 /tmp/cap.log 提取请求体**：找到 `=== REQUEST ===` 段，按日志里
   标注的 Content-Length 精确切出 JSON（多一字节都会解析失败）。

4. **改写与脱敏**（都在本地完成，再传上来）：
   - `"max_tokens"` → `1`（预热只为刷 LRU 时钟，不产出内容）
     （Codex /v1/responses 载荷无此字段，保持原样即可）
   - 保留 `"stream": true`（TTFT 从流式首字节计）
   - 检查并替换个人路径：`/Users/<name>/` → `/HOME/`、memory 目录
     路径 → `/HOME/.claude/projects/-PROJECT-SLUG/memory/` 等占位符
   - 删掉/替换私有规则正文与真实项目名——**载荷里不应能认出是谁抓的**
   - 确认体内没有 token（凭据在 header，不在体里，但复查一遍）

5. **部署**（0600，目录已 gitignore，不入库）：

       scp 载荷.json lab-bio:~/manage/appnet/warmup-payloads/<客户端>-<版本>.json
       ssh lab-bio 'chmod 600 ~/manage/appnet/warmup-payloads/*.json'
       ssh lab-bio '/home/bio/manage/appnet/scripts/dgx-warmup.sh'
       ssh lab-bio 'tail -2 /home/bio/manage/appnet/logs/dgx-warmup.log'   # 期望 ttff≈2s

## 模型名红线

脚本统一用主名 `qwen3.8-flash-next`。**别**改成 `-nothink`：网关对它
注入不同的 chat_template_kwargs，渲染出的 prompt 不同，预热无效。

## 防串扰纪律

- 载荷已脱敏：不含个人路径、私有规则原文、真实项目名
- 凭据只存在于 0600 的 `config/dgx-warmup.env`（gitignore），不进任何日志
- 脚本日志只记 `http=CODE ttff=X total=Y`，不打体、不打头
- 载荷与 env 均不入库；抓包日志用完即删

## 现状（2026-09-18 实测）

| 场景 | 首字延迟 |
|---|---|
| 冷（token 0 即失配） | ~6.1 s |
| 预热后，同版本他人新会话 | ~2.1–2.2 s |
| 预热后 10–11 分钟（一个 cron 周期内） | ~2.0–2.1 s |

已覆盖家族：`claude-code-2.1.274`、`zcode-3.12.3`（Anthropic 协议）、
`codex-cli-0.152.0`（Responses 协议）——三族热态 ttff 均 ≈1.6–3 s。

**Codex 说明（2026-09-19 更新）**：Codex 默认请求带一个 `web_search`
服务端工具（无 `input_schema`），上游 vLLM 会拒。**网关现已部署
tool-filter 自动剔除**（dgx-portal `services/new-api/`），所以载荷里
带不带它都能预热成功；现有 `codex-cli-0.152.0.responses.json` 是删掉
该工具后抓的，继续有效（上游渲染结果相同，前缀一致）。

效果边界：只覆盖**与已抓载荷同前缀**的客户端版本。Claude Code 升级
后 system/tools 变化时需重抓；团队里出现新接入工具时按上面 5 步补。
