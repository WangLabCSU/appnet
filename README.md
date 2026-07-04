# AppNet - 服务器应用反向代理管理系统

一个专业、可靠、易于运维的服务器应用反向代理管理架构。使用Caddy作为反向代理，支持前后端分离和单体应用，提供统一的配置管理和应用生命周期管理。

## ✨ 特性

- **统一配置管理** - 使用YAML配置文件管理所有应用
- **应用生命周期管理** - 支持添加、删除、启动、停止、重启应用
- **Landing Page** - 炫酷的团队展示页面，支持中英文切换
- **前后端分离支持** - 内置跨域解决方案
- **动态配置生成** - 自动根据配置生成Caddyfile
- **统一的命令行工具** - 所有运维操作通过 `app-manager.sh` 完成
- **Git版本控制** - 配置变更可追溯

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
│   └── app-manager.sh    # 统一管理工具
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
# 停止所有服务和Caddy
./scripts/app-manager.sh stop

# 或停止单个应用
./scripts/app-manager.sh stop otk
```

## 📝 应用管理

### 统一管理命令

```bash
# 查看帮助
./scripts/app-manager.sh

# 启动服务
./scripts/app-manager.sh start           # 启动所有应用和Caddy
./scripts/app-manager.sh start otk       # 启动单个应用

# 停止服务
./scripts/app-manager.sh stop            # 停止所有服务和Caddy
./scripts/app-manager.sh stop otk        # 停止单个应用

# 重启应用
./scripts/app-manager.sh restart otk     # 重启单个应用

# 查看状态
./scripts/app-manager.sh status          # 查看所有服务状态

# 配置管理
./scripts/app-manager.sh list            # 列出所有应用
./scripts/app-manager.sh ports           # 显示端口使用情况
./scripts/app-manager.sh update          # 更新配置并重启Caddy
./scripts/app-manager.sh reload          # 重载Caddy配置

# 应用管理
./scripts/app-manager.sh add myapp monolith 3000    # 添加单体应用
./scripts/app-manager.sh add myapp fullstack 3000  # 添加前后端分离应用
./scripts/app-manager.sh remove myapp               # 删除应用
```

## ⚙️ 配置文件

应用配置位于 `config/apps.yaml`：

```yaml
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

  # 自定义启动脚本应用
  - name: otk
    type: custom
    description: "OTK Prediction API"
    start_script: otk_api/start_api.sh
    env:
      API_PORT: 28884
      OTK_BASE_PATH: /otk
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
| OTK API | http://server:8880/otk/ | ecDNA预测分析平台 |
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
| Demo1 Backend | 28881 | API服务 |
| Demo1 Frontend | 28883 | 前端服务 |
| Demo2 | 28882 | 完整应用 |
| OTK API | 28884 | Python/FastAPI |

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

## 📝 日志

日志文件存储在 `logs/` 目录：
- `access.log` - Caddy访问日志
- `{app-name}.log` - 应用日志
- `{app-name}.pid` - 进程ID文件

查看日志：

```bash
# 查看应用日志
tail -f logs/otk.log

# 查看Caddy访问日志
tail -f logs/access.log
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

### 端口被占用

```bash
# 查看端口占用
lsof -i :8880

# 释放端口
fuser -k 8880/tcp
```

### 服务无法启动

```bash
# 查看状态
./scripts/app-manager.sh status

# 查看日志
tail -f logs/otk.log

# 检查配置
./scripts/app-manager.sh list
```

### 重新生成Caddyfile

```bash
./scripts/app-manager.sh reload
```

### 应用无法通过代理访问

检查Caddy路由顺序，应用路由应该优先于landing page处理器。

## 📄 许可证

MIT License

## 🤝 贡献

欢迎提交Issue和Pull Request！
