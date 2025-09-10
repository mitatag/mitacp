#!/bin/bash
# MITACP + OpenLiteSpeed + PHP7.4 + MariaDB + phpMyAdmin + File Manager + Default VH + 404

set -euo pipefail

# إعداد المتغيرات
ADMIN_USER="admin"
ADMIN_PASS="admin123456"
IP=$(curl -s https://ipinfo.io/ip)

# تحديث النظام وتثبيت الأدوات الأساسية
dnf update -y
dnf install wget unzip curl epel-release git sudo -y

# تثبيت مستودع LiteSpeed
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.1-1.el8.noarch.rpm || echo "Repo already installed"

# تثبيت OpenLiteSpeed + PHP7.4
dnf install openlitespeed lsphp74 lsphp74-common lsphp74-xml lsphp74-mbstring lsphp74-mysqli lsphp74-pdo_mysql -y
systemctl enable lsws
systemctl start lsws

# تثبيت MariaDB
dnf install mariadb-server -y
systemctl enable mariadb
systemctl start mariadb
mysql_secure_installation

# إنشاء قاعدة بيانات MITACP
mysql -uroot -p -e "CREATE DATABASE IF NOT EXISTS mitacp;"

# تثبيت phpMyAdmin
dnf install phpmyadmin -y

# تنزيل لوحة MITACP
cd /var/www/
wget https://raw.githubusercontent.com/mitatag/mitacp/main/panel.zip
unzip panel.zip -d mitacp
rm -f panel.zip

# إعداد config.php للوحة
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

chown -R nobody:nobody /var/www/mitacp
chmod -R 755 /var/www/mitacp

# تثبيت Tiny File Manager داخل اللوحة
mkdir -p /var/www/mitacp/files
cd /var/www/mitacp/files
wget https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php
echo "<?php \$auth_users = array('$ADMIN_USER' => '$ADMIN_PASS'); ?>" > config.php

# إعداد Default VH للـ IP المباشر
mkdir -p /usr/local/lsws/DEFAULT/html
echo "<!DOCTYPE html>
<html>
<head><title>Welcome to LiteSpeed</title></head>
<body>
<h1>Welcome to LiteSpeed Web Server!</h1>
</body>
</html>" > /usr/local/lsws/DEFAULT/html/index.html

# صفحة 404 لأي دومين غير معرف
echo "<!DOCTYPE html>
<html>
<head><title>404 Not Found</title></head>
<body>
<h1>404 Not Found</h1>
<p>The requested URL was not found on this server.</p>
</body>
</html>" > /usr/local/lsws/DEFAULT/html/404.html

# إعداد Default VH
mkdir -p /usr/local/lsws/conf/vhosts/DEFAULT
cat > /usr/local/lsws/conf/vhosts/DEFAULT/vhost.conf <<EOL
docRoot /usr/local/lsws/DEFAULT/html
vhDomain *
vhAliases *
adminEmails admin@example.com
enableGzip 1
errorlog \$SERVER_ROOT/logs/default_error.log
accesslog \$SERVER_ROOT/logs/default_access.log
index { useServer 0 indexFiles index.html 404.html }
EOL

# إنشاء VH للوحة MITACP على 8088
mkdir -p /usr/local/lsws/conf/vhosts/mitacp
cat > /usr/local/lsws/conf/vhosts/mitacp/vhost.conf <<EOL
docRoot /var/www/mitacp
vhDomain $IP
vhAliases *
adminEmails admin@example.com
enableGzip 1
errorlog \$SERVER_ROOT/logs/mitacp_error.log
accesslog \$SERVER_ROOT/logs/mitacp_access.log
index { useServer 0 indexFiles index.php }
EOL

# فتح كل البورتات الأساسية في firewalld
systemctl enable firewalld
systemctl start firewalld
firewall-cmd --permanent --add-port=8088/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --reload

# إعادة تشغيل OpenLiteSpeed
systemctl restart lsws

echo "=== التثبيت اكتمل ==="
echo "MITACP Panel: http://$IP:8088"
echo "مدير الملفات: http://$IP:8088/files/tinyfilemanager.php"
echo "Admin: $ADMIN_USER / Password: $ADMIN_PASS"
echo "IP مباشر يظهر صفحة Index: http://$IP"
echo "أي دومين غير معرف يظهر صفحة 404"
