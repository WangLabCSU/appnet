#!/usr/bin/env bash
# 安装 AppNet 自动更新 systemd timer

set -e

echo "安装 AppNet 自动更新服务..."

# 创建 timer
sudo tee /etc/systemd/system/appnet-update.timer > /dev/null << 'EOF'
[Unit]
Description=AppNet Auto Update Timer

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 创建 service
#
# KillMode=process 是必需的，不是可选优化：
# 本服务是 oneshot，update-app 会通过 restart_app 拉起长期运行的应用进程。
# 默认的 KillMode=control-group 会在本 service 退出时清理整个 cgroup，
# 把刚刚重启出来的应用一并 SIGTERM 掉——启动脚本往往还没执行完就被杀，
# 日志里却已经打印了「更新完成」。2026-10-16 bizard-mcp 就这样静默停摆。
# KillMode=process 只终止主进程，留下的应用进程由 appnet 自己管理。
sudo tee /etc/systemd/system/appnet-update.service > /dev/null << 'EOF'
[Unit]
Description=AppNet Auto Update Service
After=network.target

[Service]
Type=oneshot
User=bio
WorkingDirectory=/home/bio/manage/appnet
ExecStart=/home/bio/.local/bin/appnet update-app
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# 启用服务
sudo systemctl daemon-reload
sudo systemctl enable appnet-update.timer
sudo systemctl start appnet-update.timer

echo "✓ 安装完成！"
echo ""
echo "查看定时器状态: systemctl list-timers | grep appnet"
echo "查看更新日志: journalctl -u appnet-update"
echo "手动更新所有应用: appnet update-app"
echo "手动更新单个应用: appnet update-app <name>"