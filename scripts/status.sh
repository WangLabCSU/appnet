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
python3 << PYTHON_SCRIPT
import yaml
import os
import subprocess

config_file = "$CONFIG_FILE"
base_dir = "$BASE_DIR"

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
    
    if app_type == 'proxy':
        print(f"  {name} (proxy)")
        for route in app.get('routes', []):
            target = route.get('target', '')
            print(f"    → Proxy to {target}")
        print("")
        continue
    
    print(f"  {name} ({app_type}):")
    
    if app_type == 'fullstack':
        services = [
            (f"{name}-backend", f"{name}-backend"),
            (f"{name}-frontend", f"{name}-frontend")
        ]
    else:
        services = [(name, name)]
    
    for service_name, pid_name in services:
        pid_file = os.path.join(base_dir, 'logs', f'{pid_name}.pid')
        
        if os.path.exists(pid_file):
            with open(pid_file, 'r') as f:
                pid = f.read().strip()
            
            try:
                # 检查进程是否存在
                os.kill(int(pid), 0)
                print(f"    ✅ {service_name} (PID: {pid})")
            except (OSError, ValueError):
                print(f"    ❌ {service_name} (PID file exists but process not running)")
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
    for route in app.get('routes', []):
        target = route.get('target', '')
        if ':' in target:
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
