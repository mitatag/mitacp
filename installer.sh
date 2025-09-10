#!/bin/bash
# MITACP Full Installer for AlmaLinux 8
# OpenLiteSpeed + PHP7.4 + MySQL 5.7 + phpMyAdmin + MITACP + File Manager + Default VH + 404 + Random Admin Password

set -euo pipefail

#-----------------------
# إعداد المتغيرات
#-----------------------
ADMIN_USER="admin"
ADMIN_PASS=$(openssl rand -base64 12)
IP=$(curl -s https://ipinfo.io/ip)

#-----------------------
# تحديث النظام وتثبيت الأدوات الأساسية
#-----------------------
dnf update -y
dnf install wget unzip curl epel-release git sudo dnf-plugins-core -y

#-----------------------
# إزالة أي تثبيت MariaDB موجود
#-----------------------
dnf remove mariadb* -y
rm -rf /var/lib/mysql

#-----------------------
# تثبيت مستودع MySQL الرسمي 5.7
#-----------------------
wget https://dev.mysql.com/get/mysql80-community-release-el8-3.noarch.rpm
dnf localinstall mysql80-community-release-el8-3.noarch.rpm -y
dnf config-manager --disable mysql80-community
dnf config-manager --enable mysql57-community

#-----------------------
# تثبيت MySQL 5.7
#-----------------------
dnf install mysql-community-server -y
systemctl enable mysqld
systemctl start mysqld

#-----------------------
# توليد root password عشوائي وتعيينه
#-----------------------
TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log | tail -1 | awk '{print $NF}')
DB_ROOT_PASS=$(openssl rand -base64 16)
mysql --connect-expired-password -uroot -p"$TEMP_PASS" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';
FLUSH PRIVILEGES;
EOF
echo "=== MySQL root password: $DB_ROOT_PASS ==="

#-----------------------
# إنشاء قاعدة بيانات MITACP
#-----------------------
mysql -uroot -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS mitacp;"

#-----------------------
# تثبيت OpenLiteSpeed + PHP7.4
#-----------------------
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.1-1.el8.noarch.rpm || echo "Repo already installed"
dnf install openlitespeed lsphp74 lsphp74-common lsphp74-xml lsphp74-mbstring lsphp74-mysqli lsphp74-pdo_mysql -y
systemctl enable lsws
systemctl start lsws

#-----------------------
# تنزيل phpMyAdmin يدوياً
#-----------------------
cd /var/www/
wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip
unzip phpMyAdmin-latest-all-languages.zip
mv phpMyAdmin-*-all-languages phpmyadmin
rm -f phpMyAdmin-latest-all-languages.zip
mkdir -p /var/www/phpmyadmin/tmp
chown -R nobody:nobody /var/www/phpmyadmin
chmod -R 755 /var/www/phpmyadmin

cat > /var/www/phpmyadmin/config.inc.php <<EOL
<?php
\$i = 0;
\$i++;
\$cfg['blowfish_secret'] = 'ChangeThisSecret123!@#';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['user'] = 'root';
\$cfg['Servers'][\$i]['password'] = '$DB_ROOT_PASS';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
?>
EOL

#-----------------------
# تنزيل لوحة MITACP
#-----------------------
cd /var/www/
wget https://raw.githubusercontent.com/mitatag/mitacp/main/panel.zip
unzip panel.zip -d mitacp
rm -f panel.zip

cat > /var/www/mitacp/config.php <<EOL
<?php
\$db_host = 'localhost';
\$db_user = 'root';
\$db_pass = '$DB_ROOT_PASS';
\$db_name = 'mitacp';
\$ADMIN_USER = '$ADMIN_USER';
\$ADMIN_PASS = password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);
?>
EOL

chown -R nobody:nobody /var/www/mitacp
chmod -R 755 /var/www/mitacp

#-----------------------
# تثبيت Tiny File Manager داخل اللوحة
#-----------------------
mkdir -p /var/www/mitacp/files
cd /var/www/mitacp/files
wget https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php
echo "<?php \$auth_users = array('$ADMIN_USER' => '$ADMIN_PASS'); ?>" > config.php

#-----------------------
# إعداد Default VH للـ IP المباشر
#-----------------------
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

#-----------------------
# إعداد Default VH
#-----------------------
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

#-----------------------
# فتح كل البورتات الأساسية في firewalld
#-----------------------
systemctl enable firewalld
systemctl start firewalld
firewall-cmd --permanent --add-port=8088/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --reload

#-----------------------
# إعادة تشغيل OpenLiteSpeed
#-----------------------
systemctl restart lsws

#-----------------------
# إظهار معلومات التثبيت
#-----------------------
echo "=== التثبيت اكتمل ==="
echo "MITACP Panel: http://$IP:8088"
echo "مدير الملفات: http://$IP:8088/files/tinyfilemanager.php"
echo "phpMyAdmin: http://$IP/phpmyadmin"
echo "MySQL root password: $DB_ROOT_PASS"
echo "Admin MITACP: $ADMIN_USER / Password: $ADMIN_PASS"
echo "IP مباشر يظهر صفحة Index: http://$IP"
echo "أي دومين غير معرف يظهر صفحة 404"
