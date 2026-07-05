#!/usr/bin/env bash
# AppNet 应用管理脚本
# 用于添加、删除、更新应用

set -e

# 获取脚本实际路径（处理符号链接）
SCRIPT_PATH="${BASH_SOURCE[0]}"
if [ -L "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
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
    add <name> <type> [port]    添加新应用
                                type: fullstack|monolith|proxy|static
                                port: 端口号（static类型不需要）
    remove <name>               删除应用
    list                        列出所有应用
    update                      更新配置并重启Caddy
    update-app [<name>]         更新应用代码（git pull + 重装）
                                不指定名称则更新所有 auto_update 应用
                                加 --force 跳过 interval 检查
    ports                       显示端口使用情况
    start [<name>]              启动应用（不指定名称则启动所有）
    stop [<name>]               停止应用（不指定名称则停止所有）
    restart <name>              重启单个应用
    status                      查看服务状态
    reload                      重载Caddy配置
    
示例:
    $0 add myapp monolith 3000
    $0 remove myapp
    $0 list
    $0 update
    $0 update-app              # 更新所有 auto_update 应用
    $0 update-app ucscxena      # 更新指定应用
    $0 start                   # 启动所有应用和Caddy
    $0 start otk        # 只启动otk
    $0 stop             # 停止所有服务和Caddy
    $0 stop otk         # 只停止otk
    $0 restart otk
    $0 status

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
    
    if [ -z "$name" ] || [ -z "$type" ]; then
        echo -e "${RED}Error: Missing arguments${NC}"
        show_help
        exit 1
    fi
    
    # static 类型不需要端口
    if [ "$type" != "static" ] && [ -z "$port" ]; then
        echo -e "${RED}Error: Port is required for non-static types${NC}"
        show_help
        exit 1
    fi
    
    # 验证类型
    if [[ ! "$type" =~ ^(fullstack|monolith|proxy|static)$ ]]; then
        echo -e "${RED}Error: Invalid type. Must be: fullstack, monolith, proxy, or static${NC}"
        exit 1
    fi
    
    # 检查应用是否已存在
    if [ -d "$APPS_DIR/$name" ]; then
        echo -e "${RED}Error: App '$name' already exists${NC}"
        exit 1
    fi
    
    if [ "$type" = "static" ]; then
        echo -e "${BLUE}Creating app: $name (type: $type)${NC}"
    else
        echo -e "${BLUE}Creating app: $name (type: $type, port: $port)${NC}"
    fi
    
    # 创建应用目录
    mkdir -p "$APPS_DIR/$name"
    
    # 根据类型创建不同的结构
    case $type in
        static)
            cat > "$APPS_DIR/$name/README.md" << EOF
# $name

Static website application.

## Structure
Place your static files (HTML, CSS, JS, images) in this directory.

## Access
- URL: /$name/

## Development
Just add your static files to this directory.
EOF
            ;;
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
elif '$type' == 'static':
    new_app = {
        'name': '$name',
        'type': '$type',
        'description': '$name static website',
        'root': '$APPS_DIR/$name',
        'routes': [
            {
                'path': '/$name',
                'type': 'full'
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
    print(f"{'Status':<8} {'Name':<15} {'Type':<12} {'Description':<30}")
    print("-" * 70)
    for app in apps:
        name = app.get('name', 'N/A')
        app_type = app.get('type', 'N/A')
        desc = app.get('description', 'N/A')[:28]
        enabled = app.get('enabled', True)
        status = "✅" if enabled is not False else "⏸️"
        print(f"{status:<8} {name:<15} {app_type:<12} {desc:<30}")
        
        routes = app.get('routes', [])
        for route in routes:
            path = route.get('path', '')
            target = route.get('target', '')
            print(f"         → {path:<20} → {target}")
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

# 启动单个应用
start_app() {
    local name=$1
    
    if [ -z "$name" ]; then
        echo -e "${RED}Error: Missing app name${NC}"
        show_help
        exit 1
    fi
    
    echo -e "${BLUE}Starting app: $name${NC}"
    
    python3 << PYTHON_SCRIPT
import yaml
import os
import subprocess
import sys

config_file = "$CONFIG_FILE"
base_dir = "$BASE_DIR"
app_name = "$name"

with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

# 查找应用
app = None
for a in config.get('apps', []):
    if a.get('name') == app_name:
        app = a
        break

if not app:
    print(f"❌ App '{app_name}' not found in config")
    sys.exit(1)

app_type = app.get('type')
enabled = app.get('enabled', True)

if enabled is False:
    print(f"⏸️  App '{app_name}' is disabled")
    sys.exit(1)

if app_type in ['proxy', 'redirect']:
    print(f"⏭️  App '{app_name}' is proxy/redirect type, no need to start")
    sys.exit(0)

app_dir = os.path.join(base_dir, 'apps', app_name)

if not os.path.exists(app_dir):
    print(f"❌ App directory not found: {app_dir}")
    sys.exit(1)

os.makedirs(os.path.join(base_dir, 'logs'), exist_ok=True)

if app_type == 'custom':
    start_script = app.get('start_script')
    if start_script:
        script_path = os.path.join(app_dir, start_script)
        if os.path.exists(script_path):
            os.chdir(app_dir)
            
            env = os.environ.copy()
            app_env = app.get('env', {})
            for key, value in app_env.items():
                env[key] = str(value)
            
            log_file = os.path.join(base_dir, 'logs', f'{app_name}.log')
            pid_file = os.path.join(base_dir, 'logs', f'{app_name}.pid')
            
            with open(log_file, 'w') as log:
                proc = subprocess.Popen(['bash', script_path], 
                                       stdout=log, 
                                       stderr=subprocess.STDOUT,
                                       start_new_session=True,
                                       env=env)
                with open(pid_file, 'w') as pf:
                    pf.write(str(proc.pid))
                print(f"✅ Started {app_name} with PID {proc.pid}")
            os.chdir(base_dir)
        else:
            print(f"❌ Start script not found: {script_path}")
            sys.exit(1)
    else:
        print(f"❌ No start_script defined for custom app")
        sys.exit(1)

elif app_type == 'monolith':
    if os.path.exists(os.path.join(app_dir, 'package.json')):
        os.chdir(app_dir)
        if not os.path.exists('node_modules'):
            subprocess.run(['npm', 'install'], capture_output=True)
        
        log_file = os.path.join(base_dir, 'logs', f'{app_name}.log')
        pid_file = os.path.join(base_dir, 'logs', f'{app_name}.pid')
        
        with open(log_file, 'w') as log:
            proc = subprocess.Popen(['npm', 'start'], 
                                   stdout=log, 
                                   stderr=subprocess.STDOUT,
                                   start_new_session=True)
            with open(pid_file, 'w') as pf:
                pf.write(str(proc.pid))
            print(f"✅ Started {app_name} with PID {proc.pid}")
        os.chdir(base_dir)
    else:
        print(f"❌ No package.json found")
        sys.exit(1)

elif app_type == 'fullstack':
    backend_dir = os.path.join(app_dir, 'backend')
    frontend_dir = os.path.join(app_dir, 'frontend')
    
    if os.path.exists(os.path.join(backend_dir, 'package.json')):
        os.chdir(backend_dir)
        if not os.path.exists('node_modules'):
            subprocess.run(['npm', 'install'], capture_output=True)
        
        log_file = os.path.join(base_dir, 'logs', f'{app_name}-backend.log')
        pid_file = os.path.join(base_dir, 'logs', f'{app_name}-backend.pid')
        
        with open(log_file, 'w') as log:
            proc = subprocess.Popen(['npm', 'start'], 
                                   stdout=log, 
                                   stderr=subprocess.STDOUT,
                                   start_new_session=True)
            with open(pid_file, 'w') as pf:
                pf.write(str(proc.pid))
            print(f"✅ Started {app_name}-backend with PID {proc.pid}")
        os.chdir(base_dir)
    
    if os.path.exists(os.path.join(frontend_dir, 'package.json')):
        os.chdir(frontend_dir)
        if not os.path.exists('node_modules'):
            subprocess.run(['npm', 'install'], capture_output=True)
        
        log_file = os.path.join(base_dir, 'logs', f'{app_name}-frontend.log')
        pid_file = os.path.join(base_dir, 'logs', f'{app_name}-frontend.pid')
        
        with open(log_file, 'w') as log:
            proc = subprocess.Popen(['npm', 'start'], 
                                   stdout=log, 
                                   stderr=subprocess.STDOUT,
                                   start_new_session=True)
            with open(pid_file, 'w') as pf:
                pf.write(str(proc.pid))
            print(f"✅ Started {app_name}-frontend with PID {proc.pid}")
        os.chdir(base_dir)
PYTHON_SCRIPT
}

# 停止单个应用
stop_app() {
    local name=$1
    
    if [ -z "$name" ]; then
        echo -e "${RED}Error: Missing app name${NC}"
        show_help
        exit 1
    fi
    
    echo -e "${YELLOW}Stopping app: $name${NC}"
    
    # 获取应用端口
    local ports=$(python3 -c "
import yaml
config_file = '$CONFIG_FILE'
with open(config_file, 'r') as f:
    config = yaml.safe_load(f)
for app in config.get('apps', []):
    if app.get('name') == '$name':
        for route in app.get('routes', []):
            target = route.get('target', '')
            if ':' in target:
                print(target.split(':')[-1])
" 2>/dev/null)
    
    # 停止应用进程（通过PID文件）
    stopped=0
    for pid_file in "$BASE_DIR/logs/${name}"*.pid; do
        if [ -f "$pid_file" ]; then
            pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$pid" ]; then
                if kill "$pid" 2>/dev/null; then
                    echo "✅ Stopped process $pid (from PID file)"
                    stopped=1
                else
                    echo "⚠️  Process $pid not running"
                fi
            fi
            rm -f "$pid_file"
        fi
    done
    
    # 通过端口停止进程
    for port in $ports; do
        if [ -n "$port" ]; then
            pids=$(lsof -ti:$port 2>/dev/null)
            if [ -n "$pids" ]; then
                for pid in $pids; do
                    if kill "$pid" 2>/dev/null; then
                        echo "✅ Stopped process $pid (on port $port)"
                        stopped=1
                    fi
                done
            fi
        fi
    done
    
    if [ $stopped -eq 0 ]; then
        echo -e "${YELLOW}No running processes found for $name${NC}"
    fi
}

# 重启单个应用
restart_app() {
    local name=$1
    
    if [ -z "$name" ]; then
        echo -e "${RED}Error: Missing app name${NC}"
        show_help
        exit 1
    fi
    
    echo -e "${BLUE}Restarting app: $name${NC}"
    stop_app "$name"
    sleep 2
    start_app "$name"
}

# 启动所有应用和Caddy
start_all() {
    echo -e "${BLUE}=== Starting AppNet Services ===${NC}"
    echo ""
    
    # 启动所有应用
    python3 << PYTHON_SCRIPT
import yaml
import os
import subprocess
import sys

config_file = "$CONFIG_FILE"
base_dir = "$BASE_DIR"

with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

apps = config.get('apps', [])
os.makedirs(os.path.join(base_dir, 'logs'), exist_ok=True)

for app in apps:
    name = app.get('name')
    app_type = app.get('type')
    enabled = app.get('enabled', True)
    
    if enabled is False:
        print(f"⏸️  Skipping disabled app: {name}")
        continue
    
    if app_type in ['proxy', 'redirect']:
        continue
    
    app_dir = os.path.join(base_dir, 'apps', name)
    
    if not os.path.exists(app_dir):
        print(f"⚠️  App directory not found: {app_dir}")
        continue
    
    if app_type == 'custom':
        start_script = app.get('start_script')
        if start_script:
            script_path = os.path.join(app_dir, start_script)
            if os.path.exists(script_path):
                os.chdir(app_dir)
                
                env = os.environ.copy()
                app_env = app.get('env', {})
                for key, value in app_env.items():
                    env[key] = str(value)
                
                log_file = os.path.join(base_dir, 'logs', f'{name}.log')
                pid_file = os.path.join(base_dir, 'logs', f'{name}.pid')
                
                with open(log_file, 'w') as log:
                    proc = subprocess.Popen(['bash', script_path], 
                                           stdout=log, 
                                           stderr=subprocess.STDOUT,
                                           start_new_session=True,
                                           env=env)
                    with open(pid_file, 'w') as pf:
                        pf.write(str(proc.pid))
                    print(f"🚀 Started {name} with PID {proc.pid}")
                os.chdir(base_dir)

print("\n✅ All enabled applications started!")
PYTHON_SCRIPT

    # 生成并启动Caddy
    echo ""
    echo -e "${BLUE}=== Starting Caddy ===${NC}"
    "$SCRIPT_DIR/generate-caddyfile.sh" > /dev/null 2>&1
    
    if pgrep -x "caddy" > /dev/null; then
        echo "🔄 Caddy is already running, reloading..."
        caddy reload --config "$BASE_DIR/Caddyfile"
    else
        caddy start --config "$BASE_DIR/Caddyfile"
    fi
    
    echo ""
    echo -e "${GREEN}=== AppNet Services Started ===${NC}"
}

# 停止所有服务和Caddy
stop_all() {
    echo -e "${YELLOW}=== Stopping AppNet Services ===${NC}"
    echo ""
    
    # 停止Caddy
    echo "Stopping Caddy..."
    if pgrep -x "caddy" > /dev/null; then
        caddy stop 2>/dev/null || true
        echo "  ✅ Caddy stopped"
    else
        echo "  ⚠️  Caddy was not running"
    fi
    
    # 停止所有应用
    echo ""
    echo "Stopping Applications..."
    
    for pid_file in "$BASE_DIR"/logs/*.pid; do
        if [ -f "$pid_file" ]; then
            service_name=$(basename "$pid_file" .pid)
            pid=$(cat "$pid_file" 2>/dev/null)
            
            if [ -n "$pid" ]; then
                if kill -0 "$pid" 2>/dev/null; then
                    kill "$pid" 2>/dev/null
                    for i in {1..5}; do
                        if ! kill -0 "$pid" 2>/dev/null; then
                            break
                        fi
                        sleep 1
                    done
                    if kill -0 "$pid" 2>/dev/null; then
                        kill -9 "$pid" 2>/dev/null || true
                    fi
                    echo "  ✅ $service_name stopped (PID: $pid)"
                else
                    echo "  ⚠️  $service_name was not running"
                fi
            fi
            rm -f "$pid_file"
        fi
    done
    
    echo ""
    echo -e "${GREEN}=== All Services Stopped ===${NC}"
}

# 显示服务状态
show_status() {
    echo -e "${BLUE}=== AppNet Service Status ===${NC}"
    echo ""
    
    # 检查 Caddy
    echo "🌐 Caddy Proxy:"
    if pgrep -x "caddy" > /dev/null; then
        pid=$(pgrep -x "caddy")
        echo "  ✅ Running (PID: $pid)"
    else
        echo "  ❌ Not running"
    fi
    
    echo ""
    
    # 检查应用
    CONFIG_FILE="$CONFIG_FILE" BASE_DIR="$BASE_DIR" python3 << 'PYTHON_SCRIPT'
import yaml
import os
import subprocess

config_file = os.environ.get('CONFIG_FILE', '')
base_dir = os.environ.get('BASE_DIR', '')

try:
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
except:
    print("Error: Could not read config file")
    exit(1)

print("📦 Applications:")
print("")

for app in config.get('apps', []):
    name = app.get('name')
    app_type = app.get('type')
    enabled = app.get('enabled', True)
    
    status_icon = "⏸️" if enabled is False else "📦"
    
    if app_type == 'proxy' or app_type == 'redirect' or app_type == 'static':
        print(f"  {status_icon} {name} ({app_type})")
        if enabled is False:
            print(f"      Status: DISABLED")
        for route in app.get('routes', []):
            path = route.get('path', '')
            target = route.get('target', '')
            if app_type == 'redirect':
                print(f"      → {path} → `{target}`")
            elif app_type == 'static':
                print(f"      → {path} (static files)")
            else:
                print(f"      → {path} → {target}")
        print("")
        continue
    
    print(f"  {status_icon} {name} ({app_type}):")
    
    if enabled is False:
        print(f"      Status: DISABLED (not started)")
        print("")
        continue
    
    # 确定服务名称和对应端口
    if app_type == 'fullstack':
        backend_port = None
        frontend_port = None
        for route in app.get('routes', []):
            target = route.get('target', '')
            route_type = route.get('type', '')
            if ':' in target and 'localhost' in target:
                port = target.split(':')[-1]
                if route_type == 'api':
                    backend_port = port
                elif route_type == 'frontend':
                    frontend_port = port
        services = [
            (f"{name}-backend", f"{name}-backend", backend_port),
            (f"{name}-frontend", f"{name}-frontend", frontend_port)
        ]
    elif app_type == 'custom':
        port = None
        for route in app.get('routes', []):
            target = route.get('target', '')
            if ':' in target and 'localhost' in target:
                port = target.split(':')[-1]
                break
        services = [(name, name, port)]
    else:
        port = None
        for route in app.get('routes', []):
            target = route.get('target', '')
            if ':' in target and 'localhost' in target:
                port = target.split(':')[-1]
                break
        services = [(name, name, port)]
    
    for service_name, pid_name, service_port in services:
        pid_file = os.path.join(base_dir, 'logs', f'{pid_name}.pid')
        is_running = False
        source = ""
        
        if os.path.exists(pid_file):
            with open(pid_file, 'r') as f:
                pid = f.read().strip()
            
            try:
                os.kill(int(pid), 0)
                is_running = True
                source = f"PID: {pid}"
            except (OSError, ValueError):
                pass
        
        # 如果 PID 文件不存在或进程未运行，检查端口
        if not is_running and service_port:
            result = subprocess.run(['lsof', '-i', f':{service_port}'], 
                                  capture_output=True, text=True)
            if result.returncode == 0:
                is_running = True
                source = f"port {service_port} (external)"
        
        if is_running:
            print(f"    ✅ {service_name} ({source})")
        else:
            print(f"    ❌ {service_name}")
    
    for route in app.get('routes', []):
        path = route.get('path', '')
        target = route.get('target', '')
        print(f"    → {path} → {target}")
    
    print("")

print("🔌 Port Usage:")
print("")
http_port = config.get('caddy', {}).get('http_port', 8880)
print(f"  Caddy:     {http_port}")

for app in config.get('apps', []):
    enabled = app.get('enabled', True)
    if enabled is False:
        continue
    
    name = app.get('name')
    container = app.get('container')
    
    for route in app.get('routes', []):
        target = route.get('target', '')
        if ':' in target and 'localhost' in target:
            port = target.split(':')[-1]
            
            # Docker 容器检测
            if container:
                result = subprocess.run(['docker', 'ps', '--filter', f'name={container}', '--format', '{{.Names}}'], 
                                      capture_output=True, text=True)
                status = "🟢" if container in result.stdout else "🔴"
                print(f"  {name}:     {port} {status} (docker: {container})")
            else:
                # 本地端口检测
                result = subprocess.run(['lsof', '-i', f':{port}'], capture_output=True, text=True)
                status = "🟢" if result.returncode == 0 else "🔴"
                print(f"  {name}:     {port} {status}")
PYTHON_SCRIPT
}

# 重载Caddy配置
reload_caddy() {
    echo -e "${BLUE}Reloading Caddy configuration...${NC}"
    
    "$SCRIPT_DIR/generate-caddyfile.sh"
    
    if pgrep -x "caddy" > /dev/null; then
        caddy reload --config "$BASE_DIR/Caddyfile"
        echo -e "${GREEN}✅ Caddy configuration reloaded${NC}"
    else
        echo -e "${YELLOW}Caddy is not running. Use 'start' to start services.${NC}"
    fi
}

# 更新单个应用的代码
update_single_app() {
    local app_name="$1"
    local force="$2"  # 是否强制更新（跳过 interval 检查）
    
    if [ -z "$app_name" ]; then
        echo -e "${RED}错误: 请指定应用名称${NC}"
        return 1
    fi
    
    # 检查应用是否存在
    local app_config=$(grep -A 30 "name: $app_name" "$CONFIG_FILE" | head -30)
    if [ -z "$app_config" ]; then
        echo -e "${RED}错误: 应用 '$app_name' 不存在${NC}"
        return 1
    fi
    
    local app_dir="$APPS_DIR/$app_name"
    if [ ! -d "$app_dir" ]; then
        echo -e "${RED}错误: 应用目录不存在: $app_dir${NC}"
        return 1
    fi
    
    # 获取全局配置
    local github_proxy=$(grep "github_proxy:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')
    local pip_mirror=$(grep "pip_mirror:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')
    
    # 获取更新配置
    local method=$(echo "$app_config" | grep "method:" | awk '{print $2}' | tr -d '"' || echo "git_pull_install")
    local reinstall_deps=$(echo "$app_config" | grep "reinstall_deps:" | awk '{print $2}' || echo "true")
    local pip_git_url=$(echo "$app_config" | grep "pip_git_url:" | awk '{print $2}' | tr -d '"')
    local interval=$(echo "$app_config" | grep "interval:" | awk '{print $2}' || echo "hourly")
    
    # 检查是否需要更新（根据 interval）
    local state_file="$app_dir/.update_state"
    if [ "$force" != "force" ] && [ -f "$state_file" ]; then
        local last_update=$(cat "$state_file")
        local now=$(date +%s)
        local diff=$((now - last_update))
        
        local interval_secs=3600  # 默认 hourly = 1小时
        case "$interval" in
            hourly)   interval_secs=3600 ;;
            daily)    interval_secs=86400 ;;
            weekly)   interval_secs=604800 ;;
            *:*)      # 支持自定义分钟数，如 "30min"
                local mins=$(echo "$interval" | sed 's/min$//')
                interval_secs=$((mins * 60))
                ;;
        esac
        
        if [ $diff -lt $interval_secs ]; then
            local remaining=$((interval_secs - diff))
            local remaining_mins=$((remaining / 60))
            echo -e "${YELLOW}  跳过 '$app_name' (${remaining_mins}分钟后更新)${NC}"
            return 0
        fi
    fi
    
    echo -e "${BLUE}正在更新应用: $app_name${NC}"
    echo "  方法: $method, 频率: $interval"
    
    local src_dir="$app_dir/src"
    local needs_restart=false
    
    case "$method" in
        git_pull)
            # 仅 git pull，不安装
            if [ -d "$src_dir/.git" ]; then
                echo "  → 检查 Git 更新..."
                cd "$src_dir"
                local current_commit=$(git rev-parse HEAD)
                
                # 使用代理加速 fetch
                if [ -n "$github_proxy" ]; then
                    local original_url=$(git remote get-url origin)
                    local proxy_url="${github_proxy}${original_url}"
                    git fetch "$proxy_url" 2>/dev/null || git fetch origin 2>/dev/null
                else
                    git fetch origin 2>/dev/null
                fi
                
                local latest_commit=$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master 2>/dev/null)
                
                if [ "$current_commit" != "$latest_commit" ]; then
                    echo "  → 拉取最新代码..."
                    git pull origin main 2>/dev/null || git pull origin master 2>/dev/null
                    needs_restart=true
                else
                    echo -e "  ${GREEN}✓ 无需更新，已是最新版本${NC}"
                fi
            fi
            ;;
            
        git_pull_install)
            # git pull + pip install -e
            if [ -d "$src_dir/.git" ]; then
                echo "  → 检查 Git 更新..."
                cd "$src_dir"
                local current_commit=$(git rev-parse HEAD)
                git fetch origin 2>/dev/null || true
                local latest_commit=$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master 2>/dev/null)
                
                if [ "$current_commit" != "$latest_commit" ]; then
                    echo "  → 拉取最新代码..."
                    git pull origin main 2>/dev/null || git pull origin master 2>/dev/null
                    
                    if [ "$reinstall_deps" = "true" ] && [ -d "$app_dir/venv" ]; then
                        echo "  → 重新安装依赖..."
                        source "$app_dir/venv/bin/activate"
                        if [ -n "$pip_mirror" ]; then
                            pip install -e ".[api]" -i "$pip_mirror" --quiet 2>/dev/null || \
                            pip install -e . -i "$pip_mirror" --quiet 2>/dev/null || true
                        else
                            pip install -e ".[api]" --quiet 2>/dev/null || \
                            pip install -e . --quiet 2>/dev/null || true
                        fi
                    fi
                    needs_restart=true
                else
                    echo -e "  ${GREEN}✓ 无需更新，已是最新版本${NC}"
                fi
            fi
            ;;
            
        pip_git)
            # pip install git+xxx
            if [ -n "$pip_git_url" ] && [ -d "$app_dir/venv" ]; then
                echo "  → 从 Git URL 安装..."
                source "$app_dir/venv/bin/activate"
                
                # 应用 GitHub 代理
                local install_url="$pip_git_url"
                if [ -n "$github_proxy" ] && [[ "$pip_git_url" == *"github.com"* ]]; then
                    install_url="${pip_git_url/github.com/${github_proxy}github.com}"
                fi
                
                if [ -n "$pip_mirror" ]; then
                    pip install -U "$install_url" -i "$pip_mirror" --quiet 2>/dev/null || true
                else
                    pip install -U "$install_url" --quiet 2>/dev/null || true
                fi
                needs_restart=true
            fi
            ;;
            
        pip_upgrade)
            # pip install -U package_name
            if [ -d "$app_dir/venv" ]; then
                local package_name=$(basename "$src_dir" 2>/dev/null || echo "$app_name")
                echo "  → 升级包: $package_name"
                source "$app_dir/venv/bin/activate"
                if [ -n "$pip_mirror" ]; then
                    pip install -U "$package_name" -i "$pip_mirror" --quiet 2>/dev/null || true
                else
                    pip install -U "$package_name" --quiet 2>/dev/null || true
                fi
                needs_restart=true
            fi
            ;;
            
        *)
            echo -e "${YELLOW}  未知更新方法: $method${NC}"
            ;;
    esac
    
    # 更新状态文件
    date +%s > "$state_file"
    
    # 重启应用（如有更新）
    if [ "$needs_restart" = "true" ]; then
        echo "  → 重启应用..."
        restart_app "$app_name"
        echo -e "${GREEN}✓ 应用 '$app_name' 更新完成${NC}"
    fi
}

# 更新所有 auto_update 应用
update_all_apps() {
    local force="$1"
    echo -e "${BLUE}检查所有 auto_update 应用...${NC}"
    
    # 从 apps.yaml 中找出所有 auto_update.enabled: true 的应用
    # 使用 awk 来正确解析 YAML 结构
    local apps=$(awk '
        /^  - name:/ { current_name=$3 }
        /auto_update:/ { has_auto_update=1 }
        /enabled: true/ && has_auto_update { 
            print current_name
            has_auto_update=0
        }
    ' "$CONFIG_FILE")
    
    if [ -z "$apps" ]; then
        echo "  无需自动更新的应用"
        return 0
    fi
    
    for app_name in $apps; do
        update_single_app "$app_name" "$force"
    done
    
    echo -e "${GREEN}✓ 所有应用检查完成${NC}"
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
        update-app)
            if [ -z "$2" ]; then
                update_all_apps
            elif [ "$2" = "--force" ]; then
                update_all_apps "force"
            elif [ "$3" = "--force" ]; then
                update_single_app "$2" "force"
            else
                update_single_app "$2"
            fi
            ;;
        ports)
            show_ports
            ;;
        start)
            if [ -z "$2" ]; then
                start_all
            else
                start_app "$2"
            fi
            ;;
        stop)
            if [ -z "$2" ]; then
                stop_all
            else
                stop_app "$2"
            fi
            ;;
        restart)
            restart_app "$2"
            ;;
        status)
            show_status
            ;;
        reload)
            reload_caddy
            ;;
        *)
            show_help
            ;;
    esac
}

main "$@"
