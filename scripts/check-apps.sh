#!/usr/bin/env bash
# AppNet 应用健康检查
# 供 systemd appnet-apps.service 的 ExecStartPost 调用
# 从 config/apps.yaml 读所有 enabled 且非 proxy/redirect/static 的应用端口，
# 用 ss 验证端口监听。全 LISTEN 返回 0，任一未监听返回 1。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$BASE_DIR/config/apps.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "check-apps: config not found: $CONFIG_FILE" >&2
    exit 1
fi

# 失败的端口列表
failed=""

CONFIG_FILE="$CONFIG_FILE" python3 << 'PYTHON_SCRIPT'
import os
import subprocess
import yaml
import sys

config_file = os.environ['CONFIG_FILE']
with open(config_file) as f:
    config = yaml.safe_load(f)

apps = config.get('apps', [])
all_ports = []
port_to_app = {}

for app in apps:
    name = app.get('name')
    app_type = app.get('type')
    enabled = app.get('enabled', True)
    if enabled is False:
        continue
    # proxy/redirect/static 不需要后端进程
    if app_type in ('proxy', 'redirect', 'static'):
        continue
    for route in app.get('routes', []):
        target = route.get('target', '')
        if ':' in target and 'localhost' in target:
            port = target.split(':')[-1]
            if port and port not in port_to_app:
                port_to_app[port] = name
                all_ports.append(port)

if not all_ports:
    print("check-apps: no app ports to check")
    sys.exit(0)

not_listening = []
for port in all_ports:
    r = subprocess.run(['ss', '-ltnH', f'sport = :{port}'],
                        capture_output=True, text=True)
    if r.stdout.strip():
        print(f"  ✅ {port_to_app[port]} :{port} listening")
    else:
        print(f"  ❌ {port_to_app[port]} :{port} NOT listening")
        not_listening.append(port)

if not_listening:
    print(f"check-apps: FAILED — ports not listening: {', '.join(not_listening)}", file=sys.stderr)
    sys.exit(1)

print("check-apps: all apps listening ✓")
PYTHON_SCRIPT
