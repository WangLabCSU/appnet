#!/usr/bin/env bash
# AppNet 应用管理脚本
# 用于添加、删除、更新应用

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$BASE_DIR/config/apps.yaml"
APPS_DIR="$BASE_DIR/apps"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 显示帮助信息
show_help() {
    cat << EOF
AppNet 应用管理工具

用法: $0 <command> [options]

命令:
    add <name> <type> <port>    添加新应用
                                type: fullstack|monolith|proxy
    remove <name>               删除应用
    list                        列出所有应用
    update                      更新配置并重启Caddy
    ports                       显示端口使用情况
    
示例:
    $0 add myapp monolith 3000
    $0 remove myapp
    $0 list
    $0 update

EOF
}

# 检查依赖
check_deps() {
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Error: python3 is required${NC}"
        exit 1
    fi
    
    if ! python3 -c "import yaml" 2>/dev/null; then
        echo -e "${YELLOW}Installing PyYAML...${NC}"
        pip3 install pyyaml -q
    fi
}

# 添加应用
add_app() {
    local name=$1
    local type=$2
    local port=$3
    
    if [ -z "$name" ] || [ -z "$type" ] || [ -z "$port" ]; then
        echo -e "${RED}Error: Missing arguments${NC}"
        show_help
        exit 1
    fi
    
    # 验证类型
    if [[ ! "$type" =~ ^(fullstack|monolith|proxy)$ ]]; then
        echo -e "${RED}Error: Invalid type. Must be: fullstack, monolith, or proxy${NC}"
        exit 1
    fi
    
    # 检查应用是否已存在
    if [ -d "$APPS_DIR/$name" ]; then
        echo -e "${RED}Error: App '$name' already exists${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Creating app: $name (type: $type, port: $port)${NC}"
    
    # 创建应用目录
    mkdir -p "$APPS_DIR/$name"
    
    # 根据类型创建不同的结构
    case $type in
        fullstack)
            mkdir -p "$APPS_DIR/$name/frontend" "$APPS_DIR/$name/backend"
            cat > "$APPS_DIR/$name/README.md" << EOF
# $name

Full-stack application with separate frontend and backend.

## Structure
- frontend/ - Frontend application
- backend/ - Backend API server

## Ports
- Frontend: $((port + 1))
- Backend: $port

## Development
\`\`\`bash
# Start backend
cd backend && npm start

# Start frontend
cd frontend && npm start
\`\`\`
EOF
            ;;
        monolith)
            cat > "$APPS_DIR/$name/README.md" << EOF
# $name

Monolithic application.

## Port
- Application: $port

## Development
\`\`\`bash
npm start
\`\`\`
EOF
            ;;
        proxy)
            cat > "$APPS_DIR/$name/README.md" << EOF
# $name

External proxy application.

## Target
- URL: localhost:$port

This is a proxy configuration only. The actual service runs externally.
EOF
            ;;
    esac
    
    # 更新配置文件
    python3 << PYTHON_SCRIPT
import yaml
import sys

config_file = "$CONFIG_FILE"

with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

# 检查是否已存在
for app in config.get('apps', []):
    if app['name'] == '$name':
        print(f"App '$name' already exists in config")
        sys.exit(1)

# 添加新应用
if '$type' == 'fullstack':
    new_app = {
        'name': '$name',
        'type': '$type',
        'description': '$name application',
        'routes': [
            {
                'path': '/$name/api',
                'target': 'localhost:$port',
                'type': 'api',
                'strip_prefix': True
            },
            {
                'path': '/$name',
                'target': 'localhost:$((port + 1))',
                'type': 'frontend',
                'strip_prefix': True
            }
        ]
    }
else:
    new_app = {
        'name': '$name',
        'type': '$type',
        'description': '$name application',
        'routes': [
            {
                'path': '/$name',
                'target': 'localhost:$port',
                'type': 'full',
                'strip_prefix': True
            }
        ]
    }

config['apps'].append(new_app)

with open(config_file, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print(f"Added app '$name' to config")
PYTHON_SCRIPT
    
    echo -e "${GREEN}✅ App '$name' created successfully!${NC}"
    echo -e "${YELLOW}Run '$0 update' to apply changes${NC}"
}

# 删除应用
remove_app() {
    local name=$1
    
    if [ -z "$name" ]; then
        echo -e "${RED}Error: Missing app name${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Removing app: $name${NC}"
    
    # 停止应用进程
    for pid_file in "$BASE_DIR/logs/${name}"*.pid; do
        if [ -f "$pid_file" ]; then
            pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$pid" ]; then
                kill "$pid" 2>/dev/null || true
                echo "Stopped process $pid"
            fi
            rm -f "$pid_file"
        fi
    done
    
    # 删除应用目录
    if [ -d "$APPS_DIR/$name" ]; then
        rm -rf "$APPS_DIR/$name"
        echo "Removed directory: $APPS_DIR/$name"
    fi
    
    # 更新配置文件
    python3 << PYTHON_SCRIPT
import yaml

config_file = "$CONFIG_FILE"

with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

config['apps'] = [app for app in config.get('apps', []) if app['name'] != '$name']

with open(config_file, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print(f"Removed app '$name' from config")
PYTHON_SCRIPT
    
    echo -e "${GREEN}✅ App '$name' removed successfully!${NC}"
    echo -e "${YELLOW}Run '$0 update' to apply changes${NC}"
}

# 列出应用
list_apps() {
    echo -e "${BLUE}=== AppNet Applications ===${NC}\n"
    
    python3 << PYTHON_SCRIPT
import yaml

config_file = "$CONFIG_FILE"

with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

apps = config.get('apps', [])
if not apps:
    print("No applications configured")
else:
    print(f"{'Name':<15} {'Type':<12} {'Description':<30}")
    print("-" * 60)
    for app in apps:
        name = app.get('name', 'N/A')
        app_type = app.get('type', 'N/A')
        desc = app.get('description', 'N/A')[:28]
        print(f"{name:<15} {app_type:<12} {desc:<30}")
        
        routes = app.get('routes', [])
        for route in routes:
            path = route.get('path', '')
            target = route.get('target', '')
            print(f"  → {path:<20} → {target}")
        print()
PYTHON_SCRIPT
}

# 更新配置
update_config() {
    echo -e "${BLUE}Updating configuration...${NC}"
    
    # 生成新的 Caddyfile
    "$SCRIPT_DIR/generate-caddyfile.sh"
    
    # 检查 Caddy 是否运行
    if pgrep -x "caddy" > /dev/null; then
        echo "Reloading Caddy..."
        caddy reload --config "$BASE_DIR/Caddyfile"
    else
        echo -e "${YELLOW}Caddy is not running. Start with: ./scripts/start.sh${NC}"
    fi
    
    echo -e "${GREEN}✅ Configuration updated!${NC}"
}

# 显示端口使用情况
show_ports() {
    echo -e "${BLUE}=== Port Usage ===${NC}\n"
    
    python3 << PYTHON_SCRIPT
import yaml

config_file = "$CONFIG_FILE"

with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

print(f"{'App':<15} {'Path':<20} {'Target':<20} {'Status':<10}")
print("-" * 70)

for app in config.get('apps', []):
    name = app.get('name', 'N/A')
    for route in app.get('routes', []):
        path = route.get('path', '')
        target = route.get('target', '')
        port = target.split(':')[-1] if ':' in target else 'N/A'
        
        # 检查端口是否被占用
        import subprocess
        try:
            result = subprocess.run(['lsof', '-i', f':{port}'], 
                                  capture_output=True, text=True)
            status = '🔴 In Use' if result.returncode == 0 else '🟢 Available'
        except:
            status = '❓ Unknown'
        
        print(f"{name:<15} {path:<20} {target:<20} {status:<10}")

print(f"\n{'Caddy':<15} {'':<20} {'localhost:{config.get('caddy', {}).get('http_port', 8880)}':<20}")
PYTHON_SCRIPT
}

# 主函数
main() {
    check_deps
    
    case "${1:-}" in
        add)
            add_app "$2" "$3" "$4"
            ;;
        remove)
            remove_app "$2"
            ;;
        list)
            list_apps
            ;;
        update)
            update_config
            ;;
        ports)
            show_ports
            ;;
        *)
            show_help
            ;;
    esac
}

main "$@"
