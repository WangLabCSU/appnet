#!/usr/bin/env bash
# AppNet 启动脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$BASE_DIR/config/apps.yaml"

cd "$BASE_DIR"

echo "=== Starting AppNet Services ==="
echo ""

# 检查依赖
check_dependencies() {
    if ! command -v python3 &> /dev/null; then
        echo "Error: python3 is required"
        exit 1
    fi
    
    if ! python3 -c "import yaml" 2>/dev/null; then
        echo "Installing PyYAML..."
        pip3 install pyyaml -q
    fi
}

# 启动应用
start_apps() {
    echo "=== Starting Applications ==="
    
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

for app in apps:
    name = app.get('name')
    app_type = app.get('type')
    enabled = app.get('enabled', True)  # 默认启用
    
    # 跳过禁用的应用
    if enabled is False:
        print(f"⏸️  Skipping disabled app: {name}")
        continue
    
    if app_type == 'proxy' or app_type == 'redirect':
        print(f"⏭️  Skipping proxy/redirect app: {name}")
        continue
    
    app_dir = os.path.join(base_dir, 'apps', name)
    
    if not os.path.exists(app_dir):
        print(f"⚠️  Warning: App directory not found: {app_dir}")
        continue
    
    if app_type == 'fullstack':
        # 启动后端
        backend_dir = os.path.join(app_dir, 'backend')
        if os.path.exists(os.path.join(backend_dir, 'package.json')):
            print(f"🚀 Starting {name}-backend...")
            os.chdir(backend_dir)
            if not os.path.exists('node_modules'):
                subprocess.run(['npm', 'install'], capture_output=True)
            
            log_file = os.path.join(base_dir, 'logs', f'{name}-backend.log')
            pid_file = os.path.join(base_dir, 'logs', f'{name}-backend.pid')
            
            with open(log_file, 'w') as log:
                proc = subprocess.Popen(['npm', 'start'], 
                                       stdout=log, 
                                       stderr=subprocess.STDOUT,
                                       start_new_session=True)
                with open(pid_file, 'w') as pf:
                    pf.write(str(proc.pid))
                print(f"   Started with PID {proc.pid}")
            os.chdir(base_dir)
        
        # 启动前端
        frontend_dir = os.path.join(app_dir, 'frontend')
        if os.path.exists(os.path.join(frontend_dir, 'package.json')):
            print(f"🚀 Starting {name}-frontend...")
            os.chdir(frontend_dir)
            if not os.path.exists('node_modules'):
                subprocess.run(['npm', 'install'], capture_output=True)
            
            log_file = os.path.join(base_dir, 'logs', f'{name}-frontend.log')
            pid_file = os.path.join(base_dir, 'logs', f'{name}-frontend.pid')
            
            with open(log_file, 'w') as log:
                proc = subprocess.Popen(['npm', 'start'], 
                                       stdout=log, 
                                       stderr=subprocess.STDOUT,
                                       start_new_session=True)
                with open(pid_file, 'w') as pf:
                    pf.write(str(proc.pid))
                print(f"   Started with PID {proc.pid}")
            os.chdir(base_dir)
    
    elif app_type == 'monolith':
        if os.path.exists(os.path.join(app_dir, 'package.json')):
            print(f"🚀 Starting {name}...")
            os.chdir(app_dir)
            if not os.path.exists('node_modules'):
                subprocess.run(['npm', 'install'], capture_output=True)
            
            log_file = os.path.join(base_dir, 'logs', f'{name}.log')
            pid_file = os.path.join(base_dir, 'logs', f'{name}.pid')
            
            with open(log_file, 'w') as log:
                proc = subprocess.Popen(['npm', 'start'], 
                                       stdout=log, 
                                       stderr=subprocess.STDOUT,
                                       start_new_session=True)
                with open(pid_file, 'w') as pf:
                    pf.write(str(proc.pid))
                print(f"   Started with PID {proc.pid}")
            os.chdir(base_dir)

print("\n✅ All enabled applications started!")
PYTHON_SCRIPT
}

# 启动 Caddy
start_caddy() {
    echo ""
    echo "=== Starting Caddy ==="
    
    # 生成 Caddyfile
    "$SCRIPT_DIR/generate-caddyfile.sh" > /dev/null 2>&1
    
    if pgrep -x "caddy" > /dev/null; then
        echo "🔄 Caddy is already running, reloading..."
        caddy reload --config "$BASE_DIR/Caddyfile"
    else
        caddy start --config "$BASE_DIR/Caddyfile"
    fi
}

# 显示访问信息
show_info() {
    echo ""
    echo "=== AppNet Services Started ==="
    echo ""
    
    python3 << PYTHON_SCRIPT
import yaml

config_file = "$CONFIG_FILE"

with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

http_port = config.get('caddy', {}).get('http_port', 8880)

print(f"🌐 Caddy Proxy: http://localhost:{http_port}")
print(f"   Default: http://localhost:{http_port}/ → {config.get('default_redirect', 'N/A')}")
print("")

for app in config.get('apps', []):
    name = app.get('name')
    enabled = app.get('enabled', True)
    if enabled is False:
        print(f"⏸️  {name}: DISABLED")
        continue
    for route in app.get('routes', []):
        path = route.get('path', '')
        print(f"📦 {name}: http://localhost:{http_port}{path}")

print("")
print("Use './scripts/status.sh' to check service status")
print("Use './scripts/stop.sh' to stop all services")
PYTHON_SCRIPT
}

# 主函数
main() {
    check_dependencies
    start_apps
    start_caddy
    show_info
}

main "$@"
