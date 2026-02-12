#!/usr/bin/env bash
# 根据 apps.yaml 生成 Caddyfile

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$BASE_DIR/config/apps.yaml"
CADDYFILE="$BASE_DIR/Caddyfile"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# 使用 Python 解析 YAML 并生成 Caddyfile
python3 - "$CONFIG_FILE" "$CADDYFILE" << 'PYTHON_SCRIPT'
import yaml
import sys

config_file = sys.argv[1]
caddyfile = sys.argv[2]

try:
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
except Exception as e:
    print(f"Error reading config: {e}")
    sys.exit(1)

caddy_config = config.get('caddy', {})
http_port = caddy_config.get('http_port', 8880)
auto_https = caddy_config.get('auto_https', False)
landing = config.get('landing', {})
landing_enabled = landing.get('enabled', False)
landing_path = landing.get('path', '/home/bio/manage/appnet/landing')

lines = []
lines.append("{")
lines.append(f"    http_port {http_port}")
lines.append(f"    auto_https {'on' if auto_https else 'off'}")
lines.append("}")
lines.append("")
lines.append(f":{http_port} {{")

if landing_enabled:
    lines.append(f"    root * {landing_path}")
    lines.append("")
    lines.append(f"    @landing path /")
    lines.append(f"    handle @landing {{")
    lines.append(f"        file_server")
    lines.append(f"    }}")
    lines.append("")

apps = config.get('apps', [])
for app in apps:
    app_name = app.get('name', 'unknown')
    app_type = app.get('type', 'proxy')
    routes = app.get('routes', [])
    
    # 处理跳转类型的应用
    if app_type == 'redirect':
        for route in routes:
            path = route.get('path', '')
            target = route.get('target', '')
            lines.append(f"    redir /{app_name} {target}")
            lines.append(f"    redir /{app_name}/* {target}")
        lines.append("")
        continue
    
    # 跳过被注释的应用（enabled: false）
    if app.get('enabled') is False:
        continue
    
    # 按路径长度降序排序，确保更具体的路径先匹配
    routes_sorted = sorted(routes, key=lambda r: len(r.get('path', '')), reverse=True)
    
    for route in routes_sorted:
        path = route.get('path', '')
        target = route.get('target', '')
        route_type = route.get('type', 'full')
        strip_prefix = route.get('strip_prefix', True)
        
        # 根据路由类型生成不同的配置
        if route_type == 'api':
            # API路由 - 使用精确匹配
            lines.append(f"    handle /{app_name}/api/* {{")
            lines.append(f"        uri strip_prefix /{app_name}/api")
            lines.append(f"        reverse_proxy {target}")
            lines.append(f"    }}")
        elif strip_prefix:
            # 需要剥离前缀的路由
            if app_name == 'otk':
                # OTK 特殊处理：使用 handle_path 剥离前缀，
                # 同时用 header_up 告知后端应用原始路径
                lines.append(f"    handle_path /{app_name}/* {{")
                lines.append(f"        reverse_proxy {target} {{")
                lines.append(f"            header_up X-Forwarded-Prefix /{app_name}")
                lines.append(f"        }}")
                lines.append(f"    }}")
            else:
                lines.append(f"    handle_path /{app_name}/* {{")
                lines.append(f"        reverse_proxy {target}")
                lines.append(f"    }}")
            # 添加不带斜杠的重定向
            lines.append(f"    redir /{app_name} /{app_name}/ 308")
        else:
            # 不剥离前缀的路由
            lines.append(f"    handle /{app_name}/* {{")
            lines.append(f"        reverse_proxy {target}")
            lines.append(f"    }}")
        lines.append("")

lines.append("    log {")
lines.append("        output file logs/access.log")
lines.append("        format json")
lines.append("    }")
lines.append("}")

with open(caddyfile, 'w') as f:
    f.write('\n'.join(lines))

print(f"Generated Caddyfile: {caddyfile}")
PYTHON_SCRIPT
