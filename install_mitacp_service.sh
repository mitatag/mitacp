#!/bin/bash

# اسم ملف الخدمة
SERVICE_FILE="/etc/systemd/system/mitacp.service"

# محتوى الخدمة
cat <<EOL | sudo tee $SERVICE_FILE
[Unit]
Description=MITACP client panel on port 2083
After=network.target

[Service]
Type=simple
User=mitacp
Group=mitacp
WorkingDirectory=/usr/local/lsws/Example/html/mitacp
ExecStart=/usr/local/lsws/lsphp74/bin/lsphp -S 0.0.0.0:2083 -t /usr/local/lsws/Example/html/mitacp
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

# إعادة تحميل systemd
sudo systemctl daemon-reload

# تمكين الخدمة لتعمل عند الإقلاع
sudo systemctl enable mitacp.service

# تشغيل الخدمة فوراً
sudo systemctl start mitacp.service

# حالة الخدمة
sudo systemctl status mitacp.service
