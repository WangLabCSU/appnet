# AppNet - 服务器应用反向代理管理系统

一个专业、可靠、易于运维的服务器应用反向代理管理架构。使用Caddy作为反向代理，支持前后端分离和单体应用，提供统一的配置管理和应用生命周期管理。

## ✨ 特性

- **统一配置管理** - 使用YAML配置文件管理所有应用
- **应用生命周期管理** - 支持添加、删除、启动、停止、重启应用
- **Landing Page** - 炫酷的团队展示页面，支持中英文切换
- **前后端分离支持** - 内置跨域解决方案
- **动态配置生成** - 自动根据配置生成Caddyfile
- **统一的命令行工具** - 所有运维操作通过 `appnet` 命令完成
- **自动更新支持** - 支持应用代码自动更新（git pull + pip install）
- **Docker容器检测** - 支持检测 Docker 容器运行状态
- **Git版本控制** - 配置变更可追溯
- **GitHub代理支持** - 内置国内镜像代理加速 git 操作

## 📁 目录结构

```
appnet/
├── config/
│   └── apps.yaml          # 应用配置文件
├── apps/                  # 应用目录
│   ├── demo1/            # 前后端分离示例
│   ├── demo2/            # 单体应用示例
│   └── otk/              # 自定义应用示例
├── landing/              # Landing Page
│   ├── index.html        # 团队展示页面
│   └── wsx.jpeg          # PI照片
├── scripts/              # 管理脚本
│   ├── app-manager.sh     # 统一管理工具
│   ├── check-apps.sh      # 应用健康检查（供 systemd unit 用）
│   └── appnet-apps.service # systemd unit 模板（开机自启）
├── logs/                 # 日志目录
├── Caddyfile             # Caddy配置文件(自动生成)
└── README.md             # 本文件
```

## 🚀 快速开始

### 1. 安装依赖

```bash
# 安装Caddy (如果未安装)
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy

# 安装Python依赖
pip3 install pyyaml
```

### 2. 安装全局命令 (可选)

将 `appnet` 安装为全局命令，方便在任何目录使用：

```bash
# 创建软链接到 ~/.local/bin
mkdir -p ~/.local/bin
ln -sf /home/bio/manage/appnet/scripts/app-manager.sh ~/.local/bin/appnet

# 确保 ~/.local/bin 在 PATH 中
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc  # 或 ~/.bashrc
source ~/.zshrc  # 或 source ~/.bashrc

# 现在可以在任何目录使用 appnet 命令
appnet status
appnet start
appnet stop otk
```

**注意**: 软链接指向项目目录中的脚本，修改 `scripts/app-manager.sh` 会自动生效。

### 3. 启动服务

```bash
# 使用全局命令
appnet start           # 启动所有应用和Caddy
appnet start otk       # 启动单个应用

# 或使用项目脚本
cd /home/bio/manage/appnet
./scripts/app-manager.sh start
```

### 4. 查看状态

```bash
appnet status
```

### 5. 停止服务

```bash
# 停止所有应用和Caddy
appnet stop

# 或停止单个应用
appnet stop otk
```

### 6. 开机自启与断电恢复（推荐）

上面 `appnet start` 启动的应用在机器断电/重启后**不会自动恢复**。要实现开机后所有应用自动恢复，需部署两套 systemd 自启：caddy 由 `caddy.service` 管，appnet 应用由 `appnet-apps.service` 管。

**前置条件**：
- 已安装 caddy 包（提供 `caddy.service`，开机自启）
- `appnet` 命令在 PATH 中（见步骤 2）
- 当前用户有 sudo 权限

**部署 Caddy 持久化**（让 caddy.service 加载 appnet 的 Caddyfile，而非默认配置）：

```bash
# 备份默认配置，软链到 appnet 的 Caddyfile
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.default.bak
sudo rm /etc/caddy/Caddyfile
sudo ln -s "$(pwd)/Caddyfile" /etc/caddy/Caddyfile
sudo systemctl restart caddy
sudo systemctl enable caddy   # 开机自启
```

> 注意：appnet 的 Caddyfile 把访问日志写到 `/var/log/caddy/appnet-access.log`（绝对路径，避开 systemd `ProtectSystem=full` 沙箱；caddy 用户可写）。部署前确认 `/var/log/caddy` 存在（caddy 包安装时自动创建）。

**部署 appnet-apps.service**（从模板生成，参数化支持换机器/换用户）：

```bash
# 在 appnet 根目录下执行，自动用当前用户和路径替换占位符
sed -e "s|__APPNET_USER__|$USER|" \
    -e "s|__APPNET_GROUP__|$(id -gn)|" \
    -e "s|__APPNET_DIR__|$(pwd)|" \
    -e "s|__APPNET_BIN__|$(command -v appnet)|" \
    scripts/appnet-apps.service > /tmp/appnet-apps.service

sudo cp /tmp/appnet-apps.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable appnet-apps.service
sudo systemctl start appnet-apps       # 首次启动
```

**验证**：

```bash
systemctl status appnet-apps caddy     # 两者都应 active
appnet status                          # 所有应用 🟢
```

**工作原理**：
- `appnet-apps.service` 设 `After=caddy.service` + `Requires=caddy.service`，caddy 先就绪再起 apps
- `Environment=APPNET_SKIP_CADDY=1` 让 `appnet start/stop` 跳过 caddy 操作（caddy 交给 `caddy.service`），避免冲突
- `ExecStartPre=appnet stop` 先清理残留进程（含进程组清理 + 端口兜底，防止端口冲突）
- `ExecStartPost=check-apps.sh` 健康检查，任一 app 未监听则返回非0
- `Restart=on-failure`：健康检查失败 → unit 重启（先 stop 清理再 start），重试到全部就绪

**范围说明**：本方案保证"开机/重启后恢复"。运行中单个应用崩溃 unit 感知不到（应用以 detached 子进程启动，脱离 cgroup）。如需运行时自愈，可加 cron 定时跑 `scripts/check-apps.sh`，失败则 `appnet start <name>`（可选，未默认开启）。

## 📝 应用管理

### 统一管理命令

```bash
# 查看帮助
appnet

# 启动服务
appnet start           # 启动所有应用和Caddy
appnet start otk       # 启动单个应用（不影响Caddy）

# 停止服务
appnet stop            # 停止所有应用和Caddy
appnet stop otk        # 停止单个应用（不影响Caddy）
# 注：设 APPNET_SKIP_CADDY=1 时，appnet start/stop 只管应用，不碰 Caddy
#     （供 appnet-apps.service 用，Caddy 交给 systemd caddy.service 管理）

# 重启应用
appnet restart otk     # 重启单个应用

# 查看状态
appnet status          # 查看所有服务状态

# 配置管理
appnet list            # 列出所有应用
appnet ports           # 显示端口使用情况
appnet update          # 更新配置并重启Caddy
appnet reload          # 重载Caddy配置

# 应用代码更新
appnet update-app              # 更新所有 auto_update 应用
appnet update-app otk          # 更新单个应用
appnet update-app --force      # 强制更新所有（跳过间隔检查）
appnet update-app otk --force  # 强制更新单个

# 应用管理
appnet add myapp monolith 3000    # 添加单体应用
appnet add myapp fullstack 3000  # 添加前后端分离应用
appnet remove myapp               # 删除应用
```

## ⚙️ 配置文件

应用配置位于 `config/apps.yaml`：

```yaml
# 全局配置
global:
  github_proxy: "https://gh-proxy.org/"  # GitHub 国内镜像代理
  pip_mirror: "https://pypi.tuna.tsinghua.edu.cn/simple"

# Caddy 全局配置
caddy:
  http_port: 8880
  admin_port: 2019
  auto_https: false

# Landing Page 配置
landing:
  enabled: true
  path: /home/bio/manage/appnet/landing

# 应用列表
apps:
  # Docker 容器应用
  - name: gitea
    type: proxy
    description: "Gitea Git Server"
    container: gitea  # Docker 容器名称（用于状态检测）
    routes:
      - path: /gitea
        target: localhost:3000
        type: full
        strip_prefix: true

  # 前后端分离应用
  - name: demo1
    type: fullstack
    description: "Gene Expression Analysis"
    routes:
      - path: /demo1/api
        target: localhost:28881
        type: api
        strip_prefix: true
      - path: /demo1
        target: localhost:28883
        type: frontend
        strip_prefix: true

  # 单体应用
  - name: demo2
    type: monolith
    description: "Survival Analysis"
    routes:
      - path: /demo2
        target: localhost:28882
        type: full
        strip_prefix: true

  # 自定义启动脚本 + 自动更新
  - name: otk
    type: custom
    description: "OTK Prediction API"
    start_script: otk_api/start_api.sh
    env:
      API_PORT: 28884
      OTK_BASE_PATH: /otk
    auto_update:
      enabled: true
      interval: daily       # hourly, daily, weekly, 或 30min
      method: git_pull_install
      git_dir: ""           # git 在 app 根目录
      venv_dir: otk_api/venv  # venv 在子目录
    routes:
      - path: /otk
        target: localhost:28884
        type: full
        strip_prefix: false

  # 外部跳转
  - name: shiny
    type: redirect
    routes:
      - path: /shiny
        target: http://biotree.top:38124/
```

## 🌐 访问地址

| 应用 | 访问地址 | 说明 |
|-----|---------|------|
| Landing Page | http://server:8880/ | WangLab团队展示页面 |
| Gitea | http://server:8880/gitea/ | Git服务器 |
| OTK API | http://server:8880/otk/ | ecDNA预测分析平台 |
| UCSCXena API | http://server:8880/ucscxena/ | TCGA数据分析API |
| Demo1 | http://server:8880/demo1/ | 前后端分离应用 |
| Demo2 | http://server:8880/demo2/ | 单体应用 |
| Shiny | http://server:8880/shiny | R Shiny应用(跳转) |

## 🎨 Landing Page

Landing Page 展示了以下内容：
- **实验室信息**: LISOM (Laboratory of In Silico Oncology and Medicine)
- **PI 简介**: 王诗翔教授信息
- **统计数据**: 开源项目、学术论文、引用数
- **应用平台**: 所有应用的入口链接
- **团队链接**: GitHub、飞书、学术资源等
- **中英文切换**: 支持一键切换语言

## 🔧 跨域解决方案

Demo1展示了前后端分离的跨域解决方案：

```
浏览器 → Caddy(8880) → 后端(28881)
                ↓
           前端(28883)
```

通过Caddy统一代理，前端和后端都通过 `/demo1/` 路径访问：
- 前端: `http://server:8880/demo1/`
- API: `http://server:8880/demo1/api/`

浏览器认为它们是同源，完全避免了跨域问题！

## 📊 端口分配

| 服务 | 端口 | 说明 |
|-----|------|------|
| Caddy | 8880 | 统一入口 |
| Gitea | 3000 | Git服务器 (Docker) |
| Demo1 Backend | 28881 | API服务 |
| Demo1 Frontend | 28883 | 前端服务 |
| Demo2 | 28882 | 完整应用 |
| OTK API | 28884 | Python/FastAPI |
| UCSCXena API | 28885 | Python/FastAPI |

## 🛠️ 开发指南

### 添加自定义应用

1. 在 `apps/` 目录下创建应用目录
2. 根据应用类型创建相应结构
3. 在 `config/apps.yaml` 中添加配置
4. 运行 `./scripts/app-manager.sh update`

### 应用类型说明

- **fullstack**: 前后端分离，包含backend和frontend目录
- **monolith**: 单体应用，所有代码在一个目录
- **custom**: 自定义启动脚本，需要指定 `start_script`
- **proxy**: 仅代理配置，不管理应用进程
- **redirect**: 跳转到外部URL

### 禁用应用

在配置中设置 `enabled: false`：

```yaml
- name: oldapp
  type: monolith
  enabled: false
  routes:
    - path: /oldapp
      target: localhost:28000
```

### 自动更新配置

支持应用代码自动更新：

```yaml
auto_update:
  enabled: true
  interval: daily        # hourly, daily, weekly, 或 30min
  method: git_pull_install  # git_pull, git_pull_install, pip_git, pip_upgrade
  git_dir: ""            # git 仓库路径（空 = app 根目录）
  venv_dir: venv         # 虚拟环境路径
```

**更新方法说明**：

| 方法 | 说明 |
|-----|------|
| `git_pull` | 仅 git pull，不安装依赖 |
| `git_pull_install` | git pull + pip install -e（推荐） |
| `pip_git` | pip install git+xxx |
| `pip_upgrade` | pip install -U package_name |

**安装 systemd 定时器**：

```bash
sudo ./scripts/install-systemd-timer.sh
```

定时器每小时运行 `appnet update-app`，每个应用根据配置的 `interval` 判断是否需要更新。

### Docker 容器应用

对于 Docker 容器应用，添加 `container` 字段用于状态检测：

```yaml
- name: gitea
  type: proxy
  container: gitea  # Docker 容器名称
  routes:
    - path: /gitea
      target: localhost:3000
```

## 📝 日志

日志文件存储位置：
- `/var/log/caddy/appnet-access.log` - Caddy 访问日志（由 caddy.service 写入，caddy 用户可写；避开了 systemd `ProtectSystem=full` 沙箱，勿改回相对路径）
- `logs/{app-name}.log` - 应用日志
- `logs/{app-name}.pid` - 进程ID文件

查看日志：

```bash
# 查看应用日志
tail -f logs/otk.log

# 查看 Caddy 访问日志（需 caddy 用户或 sudo）
sudo tail -f /var/log/caddy/appnet-access.log

# 查看 appnet-apps.service 启动日志
journalctl -u appnet-apps -b --no-pager | tail -30
```

## 🔒 Git版本控制

```bash
# 查看变更
git status

# 添加配置变更
git add config/apps.yaml
git commit -m "Add new application"

# 查看历史
git log
```

## 🐛 故障排除

### Caddy 在跑但应用访问 502/无法访问

最常见原因：caddy 进程在跑，但加载的不是 appnet 配置（如重启后 systemd 加载了默认 `/etc/caddy/Caddyfile`）。诊断：

```bash
appnet status
# 若显示 "⚠️ Running (PID) but NOT listening on :8880 — wrong config?"
# 说明 caddy 加载了错误配置

# 验证：检查 /etc/caddy/Caddyfile 是否软链到 appnet
ls -la /etc/caddy/Caddyfile
# 应显示 -> /home/.../appnet/Caddyfile，否则按"开机自启"章节重新软链
```

### 应用进程残留导致端口被占用

`appnet stop` 会清理进程组 + 端口兜底，但极端情况（如 kill -9 后）可能残留。诊断用 `ss`（非 root 可靠，`lsof` 对其他用户进程不可靠）：

```bash
# 查看端口监听情况
ss -ltnp 'sport = :28884'

# 强制清理（替换为实际 pid）
kill -9 <pid>
```

### appnet-apps.service 启动失败

```bash
# 查看 unit 日志（含 stop 清理 → start → check-apps 各阶段）
journalctl -u appnet-apps -b --no-pager | tail -50

# 手动复现 unit 流程排查
APPNET_SKIP_CADDY=1 appnet stop
APPNET_SKIP_CADDY=1 appnet start
./scripts/check-apps.sh   # 应返回 0
```

### 服务无法启动

```bash
# 查看状态
appnet status

# 查看应用日志
tail -f logs/otk.log

# 检查配置
appnet list
```

### 重新生成 Caddyfile

```bash
appnet reload
```

### 应用无法通过代理访问

检查Caddy路由顺序，应用路由应该优先于landing page处理器。

## 📄 许可证

MIT License

## 🤝 贡献

欢迎提交Issue和Pull Request！
