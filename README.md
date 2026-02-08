# AppNet - 服务器应用反向代理管理系统

一个专业、可靠、易于运维的服务器应用反向代理管理架构。使用Caddy作为反向代理，支持前后端分离和单体应用，提供统一的配置管理和应用生命周期管理。

## ✨ 特性

- **统一配置管理** - 使用YAML配置文件管理所有应用
- **应用生命周期管理** - 支持添加、删除、更新应用
- **前后端分离支持** - 内置跨域解决方案
- **动态配置生成** - 自动根据配置生成Caddyfile
- **完整的运维脚本** - 启动、停止、状态检查、端口管理
- **Git版本控制** - 配置变更可追溯

## 📁 目录结构

```
appnet/
├── config/
│   └── apps.yaml          # 应用配置文件
├── apps/                  # 应用目录
│   ├── demo1/            # 前后端分离示例
│   │   ├── backend/      # 后端API
│   │   ├── frontend/     # 前端应用
│   │   └── README.md
│   └── demo2/            # 单体应用示例
│       ├── app.js
│       ├── index.html
│       └── package.json
├── scripts/               # 管理脚本
│   ├── start.sh          # 启动所有服务
│   ├── stop.sh           # 停止所有服务
│   ├── status.sh         # 查看服务状态
│   ├── app-manager.sh    # 应用管理工具
│   └── generate-caddyfile.sh  # Caddyfile生成器
├── logs/                  # 日志目录
├── docs/                  # 文档目录
├── Caddyfile             # Caddy配置文件(自动生成)
├── .gitignore            # Git忽略配置
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

### 2. 启动服务

```bash
cd /home/bio/manage/appnet
./scripts/start.sh
```

### 3. 查看状态

```bash
./scripts/status.sh
```

### 4. 停止服务

```bash
./scripts/stop.sh
```

## 📝 应用管理

### 添加新应用

```bash
# 添加单体应用
./scripts/app-manager.sh add myapp monolith 3000

# 添加前后端分离应用
./scripts/app-manager.sh add myapp fullstack 3000

# 添加代理应用
./scripts/app-manager.sh add myapp proxy 3000
```

### 删除应用

```bash
./scripts/app-manager.sh remove myapp
```

### 列出所有应用

```bash
./scripts/app-manager.sh list
```

### 查看端口使用情况

```bash
./scripts/app-manager.sh ports
```

### 更新配置

```bash
./scripts/app-manager.sh update
```

## ⚙️ 配置文件

应用配置位于 `config/apps.yaml`：

```yaml
# Caddy 全局配置
caddy:
  http_port: 8880
  admin_port: 2019
  auto_https: false

# 默认跳转
default_redirect: https://oncoharmony-network.github.io/

# 应用列表
apps:
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

  - name: demo2
    type: monolith
    description: "Survival Analysis"
    routes:
      - path: /demo2
        target: localhost:28882
        type: full
        strip_prefix: true
```

## 🌐 访问地址

| 应用 | 访问地址 | 说明 |
|-----|---------|------|
| 默认 | http://server:8880/ | 跳转到OncoHarmony |
| Demo1 | http://server:8880/demo1 | 前后端分离应用 |
| Demo1 API | http://server:8880/demo1/api | 后端API |
| Demo2 | http://server:8880/demo2 | 单体应用 |
| Shiny | http://server:8880/shiny | R Shiny应用 |

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
| Shiny | 3838 | 外部Shiny |

## 🛠️ 开发指南

### 添加自定义应用

1. 在 `apps/` 目录下创建应用目录
2. 根据应用类型创建相应结构
3. 在 `config/apps.yaml` 中添加配置
4. 运行 `./scripts/app-manager.sh update`

### 应用类型说明

- **fullstack**: 前后端分离，包含backend和frontend目录
- **monolith**: 单体应用，所有代码在一个目录
- **proxy**: 仅代理配置，不管理应用进程

## 📝 日志

日志文件存储在 `logs/` 目录：
- `access.log` - Caddy访问日志
- `{app-name}.log` - 应用日志
- `{app-name}.pid` - 进程ID文件

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
# 查看日志
tail -f logs/demo1-backend.log

# 检查配置
./scripts/app-manager.sh list
```

### 重新生成Caddyfile

```bash
./scripts/generate-caddyfile.sh
```

## 📄 许可证

MIT License

## 🤝 贡献

欢迎提交Issue和Pull Request！
