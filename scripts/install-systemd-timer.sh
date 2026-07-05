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
sudo tee /etc/systemd/system/appnet-update.service > /dev/null << 'EOF'
[Unit]
Description=AppNet Auto Update Service
After=network.target

[Service]
Type=oneshot
User=bio
WorkingDirectory=/home/bio/manage/appnet
ExecStart=/home/bio/.local/bin/appnet update-app

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