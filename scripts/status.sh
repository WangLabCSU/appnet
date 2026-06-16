#!/usr/bin/env bash
# AppNet 状态检查脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$BASE_DIR/config/apps.yaml"

cd "$BASE_DIR"

echo "=== AppNet Service Status ==="
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
    
    # 显示禁用状态
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
        # 从 routes 中获取 backend 和 frontend 的端口
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
        # 从 routes 获取端口
        port = None
        for route in app.get('routes', []):
            target = route.get('target', '')
            if ':' in target and 'localhost' in target:
                port = target.split(':')[-1]
                break
        services = [(name, name, port)]
    else:
        # 从 routes 获取端口
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
    
    # 显示路由信息
    for route in app.get('routes', []):
        path = route.get('path', '')
        target = route.get('target', '')
        print(f"    → {path} → {target}")
    
    print("")

# 显示端口使用情况
print("🔌 Port Usage:")
print("")
http_port = config.get('caddy', {}).get('http_port', 8880)
print(f"  Caddy:     {http_port}")

for app in config.get('apps', []):
    enabled = app.get('enabled', True)
    if enabled is False:
        continue
    for route in app.get('routes', []):
        target = route.get('target', '')
        if ':' in target and 'localhost' in target:
            port = target.split(':')[-1]
            name = app.get('name')
            # 检查端口是否被监听
            result = subprocess.run(['lsof', '-i', f':{port}'], 
                                  capture_output=True, text=True)
            status = "🟢" if result.returncode == 0 else "🔴"
            print(f"  {name}:     {port} {status}")
PYTHON_SCRIPT

echo ""
echo "Use './scripts/start.sh' to start services"
echo "Use './scripts/stop.sh' to stop services"
