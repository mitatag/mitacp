#!/bin/bash
# MITACP Installer - OpenLiteSpeed + PHP7.4 + MySQL 5.7 + phpMyAdmin

set -euo pipefail

echo "=== Cleaning previous installations ==="
systemctl stop lsws || true
systemctl stop mysqld || true
dnf remove -y openlitespeed lsphp* mysql* mariadb* phpmyadmin || true
rm -rf /var/www/mitacp /var/www/phpmyadmin /usr/local/lsws/DEFAULT/html || true
rm -rf /var/log/mariadb /var/log/mysql || true

#-----------------------
# Input credentials
#-----------------------
read -p "Enter MITACP admin username: " ADMIN_USER
read -sp "Enter MITACP admin password: " ADMIN_PASS
echo
read -sp "Enter MySQL root password: " DB_ROOT_PASS
echo

#-----------------------
# Update system and install basic tools
#-----------------------
dnf update -y
dnf install wget unzip curl epel-release git sudo -y

#-----------------------
# Install LiteSpeed
#-----------------------
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.1-1.el8.noarch.rpm || true
dnf install -y openlitespeed lsphp74 lsphp74-common lsphp74-xml lsphp74-mbstring lsphp74-mysqlnd lsphp74-pdo lsphp74-process

systemctl enable lsws
systemctl start lsws

#-----------------------
# Install MySQL 5.7
#-----------------------
wget https://repo.mysql.com/mysql57-community-release-el8-11.noarch.rpm
dnf localinstall -y mysql57-community-release-el8-11.noarch.rpm
dnf config-manager --disable mysql80-community
dnf config-manager --enable mysql57-community
dnf install -y mysql-community-server

systemctl enable mysqld
systemctl start mysqld

#-----------------------
# Secure MySQL (manual)
#-----------------------
mysql_secure_installation

#-----------------------
# Create MITACP database
#-----------------------
mysql -uroot -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS mitacp;"

#-----------------------
# Install phpMyAdmin
#-----------------------
cd /var/www/
wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip
unzip phpMyAdmin-latest-all-languages.zip
mv phpMyAdmin-*-all-languages phpmyadmin
rm -f phpMyAdmin-latest-all-languages.zip
mkdir -p /var/www/phpmyadmin/tmp
chown -R nobody:nobody /var/www/phpmyadmin
chmod -R 755 /var/www/phpmyadmin

# phpMyAdmin config
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
# Install MITACP Panel
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
# Install Tiny File Manager
#-----------------------
mkdir -p /var/www/mitacp/files
cd /var/www/mitacp/files
wget https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php
echo "<?php \$auth_users = array('$ADMIN_USER' => '$ADMIN_PASS'); ?>" > config.php

#-----------------------
# Default VH & 404
#-----------------------
mkdir -p /usr/local/lsws/DEFAULT/html
echo "<!DOCTYPE html><html><head><title>Welcome to LiteSpeed</title></head><body><h1>Welcome to LiteSpeed Web Server!</h1></body></html>" > /usr/local/lsws/DEFAULT/html/index.html

echo "<!DOCTYPE html><html><head><title>404 Not Found</title></head><body><h1>404 Not Found</h1><p>The requested URL was not found on this server.</p></body></html>" > /usr/local/lsws/DEFAULT/html/404.html

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

#-----------------------
# Open firewall
#-----------------------
systemctl enable firewalld
systemctl start firewalld
firewall-cmd --permanent --add-port=8088/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --reload

#-----------------------
# Restart OpenLiteSpeed
#-----------------------
systemctl restart lsws

#-----------------------
# Finished
#-----------------------
IP=$(curl -s https://ipinfo.io/ip)
echo "=== Installation Complete ==="
echo "MITACP Panel: http://$IP:8088"
echo "File Manager: http://$IP:8088/files/tinyfilemanager.php"
echo "phpMyAdmin: http://$IP/phpmyadmin"
echo "MySQL root password: $DB_ROOT_PASS"
echo "Admin MITACP: $ADMIN_USER / Password: $ADMIN_PASS"
echo "Direct IP shows Index page: http://$IP"
echo "Any undefined domain shows 404 page"
