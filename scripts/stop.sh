#!/usr/bin/env bash
# AppNet 停止脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

cd "$BASE_DIR"

echo "=== Stopping AppNet Services ==="
echo ""

# 停止 Caddy
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

for pid_file in logs/*.pid; do
    if [ -f "$pid_file" ]; then
        service_name=$(basename "$pid_file" .pid)
        pid=$(cat "$pid_file" 2>/dev/null)
        
        if [ -n "$pid" ]; then
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                # 等待进程结束
                for i in {1..5}; do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        break
                    fi
                    sleep 1
                done
                # 强制终止
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
echo "=== All Services Stopped ==="
