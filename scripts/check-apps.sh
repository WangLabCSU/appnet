#!/usr/bin/env bash
# AppNet 应用健康检查
# 供 systemd appnet-apps.service 的 ExecStartPost 调用
# 从 config/apps.yaml 读所有 enabled 且非 proxy/redirect/static 的应用端口，
# 用 ss 验证端口监听。全部 LISTEN 返回 0，超时仍有端口未监听返回 1。
#
# 冷启动宽限：应用启动后端口需要数秒到数十秒才就绪（uvicorn 加载模型、
# npm 冷启动等）。ExecStartPost 一旦返回非 0，systemd 会杀掉整个 cgroup
# 并按 Restart=on-failure 重试——无宽限的即时检查在断电重启后必然陷入
# 无限重启循环（2026-10-15 断电后实测重启计数 7600+）。因此这里每 2 秒
# 重扫一次端口，最长等待 90 秒（须在 unit 的 TimeoutStartSec=120s 之内）。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$BASE_DIR/config/apps.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "check-apps: config not found: $CONFIG_FILE" >&2
    exit 1
fi

CONFIG_FILE="$CONFIG_FILE" python3 << 'PYTHON_SCRIPT'
import os
import subprocess
import time
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

DEADLINE_SECONDS = 90
POLL_INTERVAL = 2

deadline = time.time() + DEADLINE_SECONDS
ready = set()

while True:
    not_listening = []
    for port in all_ports:
        r = subprocess.run(['ss', '-ltnH', f'sport = :{port}'],
                           capture_output=True, text=True)
        if r.stdout.strip():
            if port not in ready:
                print(f"  ✅ {port_to_app[port]} :{port} listening")
                ready.add(port)
        else:
            not_listening.append(port)

    if not not_listening:
        print("check-apps: all apps listening ✓")
        sys.exit(0)

    if time.time() >= deadline:
        for port in not_listening:
            print(f"  ❌ {port_to_app[port]} :{port} NOT listening", file=sys.stderr)
        print(f"check-apps: FAILED — ports not listening: {', '.join(not_listening)}", file=sys.stderr)
        sys.exit(1)

    time.sleep(POLL_INTERVAL)
PYTHON_SCRIPT
