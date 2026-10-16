# bizard-mcp

[Bizard](https://openbiox.github.io/Bizard/) 生物医学可视化图表库的 MCP 共享服务（Streamable HTTP），
供团队成员免安装直接通过 URL 接入。服务端代码跟踪 [openbiox/Bizard](https://github.com/openbiox/Bizard)
的 `main` 分支，**每小时自动检查更新**，有提交即自动构建并重启，无需人工干预。

## 用户接入

支持 Streamable HTTP 的 MCP 客户端（Claude Code、Claude Desktop、Cursor 等）：

```bash
# Claude Code 示例
claude mcp add --transport http bizard http://biotree.top:38123/bizard-mcp/mcp
```

- 服务端点固定为 `{base}/mcp`（POST），匿名可用，内置 per-IP 限流（60 req/min）
- 工具：`bizard_search` / `bizard_list_categories` / `bizard_get_tutorial` / `bizard_get_code` /
  `bizard_adapt_guidance` / `bizard_cite` / `bizard_contribute_check` / `bizard_contribute_submit`
- 公网入口（natcross）：`http://biotree.top:38123/bizard-mcp/mcp`；内网/Caddy 直挂：`http://<server>:8880/bizard-mcp/mcp`

## 目录结构

```
apps/bizard-mcp/
├── start.sh        # 启动脚本（幂等；首次自动引导 Node20 + 克隆 + 构建）
├── bizard-mcp.pid  # 运行 pid（运行时生成，不入库）
├── service.log     # 服务日志（运行时生成，不入库）
└── repo/           # Bizard 浅克隆（首次启动生成，.gitignore 排除，不入库）
    └── mcp/        # npm 包目录：node_modules/、dist/（构建产物）都在其中
```

入库的只有 `start.sh` 和本文档；`repo/` 及其中 node_modules、dist、内容快照均为运行时缓存。

## 运行原理

1. **Node 运行时**：bizard-mcp 要求 Node ≥ 20。服务器系统 Node 为 18 时，
   `start.sh` 经 `scripts/node-env.sh` 用户态安装 Node 20 到 `~/.local/node20`（免 sudo，
   可用 `NODE20_VERSION` 换版本，`NODE20_SKIP_BOOTSTRAP=1` 禁用自动安装）。
2. **首次构建**：`git clone --depth 20`（走 apps.yaml 的 `github_proxy`）→
   `npm ci`（走 apps.yaml 的 `npm_registry`，可留空；只读 lockfile 不污染工作区）→
   `npm run build:bundle`（从画廊 CSV/教程 QMD 生成内容快照）→ `npm run build`（tsc + 拷贝快照）。
3. **服务进程**：`node repo/mcp/dist/index.js --http`，监听 `BIZARD_HTTP_PORT`（默认 28892），
   仅本机回环可达，由 Caddy `/bizard-mcp` 反代（strip_prefix）对外。
4. **自动更新**：`config/apps.yaml` 中 `auto_update.method: git_pull_npm`，由 systemd
   `appnet-update.timer`（每小时）驱动 `appnet update-app bizard-mcp`：
   `git pull` → `npm ci` → `build:bundle` → `build` → 重启。

## 运维命令

```bash
appnet restart bizard-mcp      # 重启（改代码/排查）
appnet update-app bizard-mcp   # 手动立即检查更新（跳过 interval 等待）
appnet stop bizard-mcp && appnet start bizard-mcp   # 全量重建（等价于重建 dist）
tail -f apps/bizard-mcp/service.log                  # 服务日志
git -C apps/bizard-mcp/repo log --oneline -3         # 当前跟踪的 Bizard 提交
```

健康检查：`scripts/check-apps.sh` 会探测 28892 端口（含在 90 秒冷启动宽限内）。

## 环境变量

| 变量 | 默认 | 说明 |
|-----|------|------|
| `BIZARD_HTTP_PORT` | `28892` | 监听端口（apps.yaml env 传入） |
| `BIZARD_REPO_URL` | `https://github.com/openbiox/Bizard.git` | 上游仓库 |
| `NODE20_VERSION` | `v20.18.1` | 用户态 Node 版本 |
| `NODE20_SKIP_BOOTSTRAP` | `0` | 置 `1` 禁用自动安装 Node（缺失时报错退出） |

服务端自身零凭据；贡献（contribute）工具在托管模式自动降级为草稿 + 深链。
