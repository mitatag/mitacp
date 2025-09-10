#!/bin/bash
# MITACP Ultimate Installer AlmaLinux 8 - محدث
# يدعم PHP7.4 + OpenLiteSpeed + MariaDB + phpMyAdmin + MITACP Panel

set -euo pipefail

SERVER_IP=$(curl -s https://ipinfo.io/ip)
ADMIN_USER="admin"
ADMIN_PASS="admin123456"

echo "=== تحديث النظام ==="
dnf update -y

echo "=== تثبيت المستلزمات الأساسية ==="
dnf install wget unzip curl epel-release git sudo -y

echo "=== تثبيت OpenLiteSpeed ==="
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.1-1.el8.noarch.rpm
dnf install openlitespeed -y

echo "=== تثبيت PHP 7.4 لـ LiteSpeed ==="
dnf install lsphp74 lsphp74-common lsphp74-xml lsphp74-mbstring lsphp74-mysqli lsphp74-pdo_mysql -y

echo "=== تمكين وتشغيل OpenLiteSpeed ==="
systemctl enable lsws
systemctl start lsws

echo "=== تثبيت MariaDB ==="
dnf install mariadb-server -y
systemctl enable mariadb
systemctl start mariadb

echo "=== إعداد MariaDB ==="
mysql_secure_installation <<EOF

y
$ADMIN_PASS
$ADMIN_PASS
y
y
y
y
EOF

echo "=== إنشاء قاعدة بيانات MITACP ==="
mysql -uroot -p$ADMIN_PASS -e "CREATE DATABASE IF NOT EXISTS mitacp;"

echo "=== تثبيت phpMyAdmin ==="
dnf install phpmyadmin -y

echo "=== تنزيل ملفات اللوحة MITACP ==="
cd /var/www/
wget https://raw.githubusercontent.com/mitatag/mitacp/main/panel.zip
unzip panel.zip -d mitacp
rm -f panel.zip

echo "=== إعداد config.php ==="
cat > /var/www/mitacp/config.php <<EOL
<?php
\$db_host = 'localhost';
\$db_user = 'root';
\$db_pass = '$ADMIN_PASS';
\$db_name = 'mitacp';
\$ADMIN_USER = '$ADMIN_USER';
\$ADMIN_PASS = password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);
?>
EOL

echo "=== أذونات الملفات ==="
chown -R nobody:nobody /var/www/mitacp
chmod -R 755 /var/www/mitacp

echo "=== تثبيت acme.sh لإصدار SSL ==="
curl https://get.acme.sh | sh

echo "=== إعداد Virtual Host افتراضي لـ MITACP ==="
mkdir -p /usr/local/lsws/conf/vhosts/mitacp
cat > /usr/local/lsws/conf/vhosts/mitacp/vhost.conf <<EOL
docRoot                   /var/www/mitacp
vhDomain                   $SERVER_IP
vhAliases                  *
adminEmails                admin@example.com
enableGzip                 1
errorlog                   \$SERVER_ROOT/logs/mitacp_error.log
accesslog                  \$SERVER_ROOT/logs/mitacp_access.log
index  {
  useServer               0
  indexFiles              index.php
}
EOL

echo "=== إعادة تشغيل OpenLiteSpeed ==="
systemctl restart lsws

echo "=== التثبيت اكتمل ==="
echo "لوحة MITACP جاهزة:"
echo "رابط الدخول: http://$SERVER_IP:8088"
echo "Admin: $ADMIN_USER / Password: $ADMIN_PASS"
