#!/bin/bash
# MITACP Full Installer for AlmaLinux 8
# OpenLiteSpeed + PHP7.4 + MySQL 5.7 + MITACP + phpMyAdmin + Tiny File Manager + Default VH + 404
# All previous installations removed before new setup

set -euo pipefail

echo "=== Cleaning previous installations ==="

# Stop services if running
systemctl stop lsws.service 2>/dev/null || true
systemctl stop mariadb.service 2>/dev/null || true
systemctl stop mysqld.service 2>/dev/null || true

# Remove old packages
dnf remove -y openlitespeed lsphp* mariadb* mysql* phpmyadmin || true

# Remove old directories
rm -rf /usr/local/lsws /var/www/mitacp /var/www/phpmyadmin /usr/local/lsws/DEFAULT /var/log/mariadb /var/lib/mysql || true

echo "=== Previous installations cleaned ==="

# Ask user input
read -p "Enter Admin username for MITACP: " ADMIN_USER
read -sp "Enter Admin password for MITACP: " ADMIN_PASS
echo ""
read -p "Enter MySQL root username (default: root): " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-root}
read -sp "Enter MySQL root password: " MYSQL_PASS
echo ""

# Update system and install basic tools
dnf update -y
dnf install wget unzip curl epel-release git sudo -y

# Install LiteSpeed repository
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.1-1.el8.noarch.rpm || echo "Repo already installed"

# Install OpenLiteSpeed and PHP 7.4
dnf install -y openlitespeed lsphp74 lsphp74-common lsphp74-xml lsphp74-mbstring lsphp74-mysqli lsphp74-pdo_mysql
systemctl enable lsws
systemctl start lsws

# Install MySQL 5.7
wget https://dev.mysql.com/get/mysql80-community-release-el8-3.noarch.rpm
dnf localinstall -y mysql80-community-release-el8-3.noarch.rpm
dnf config-manager --disable mysql80-community
dnf config-manager --enable mysql57-community
dnf install -y mysql-community-server
systemctl enable mysqld
systemctl start mysqld

# Secure MySQL and set root password
mysqladmin -u$MYSQL_USER password "$MYSQL_PASS" || true

# Create MITACP database
mysql -u$MYSQL_USER -p"$MYSQL_PASS" -e "CREATE DATABASE IF NOT EXISTS mitacp;"

# Download phpMyAdmin
cd /var/www/
wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip
unzip phpMyAdmin-latest-all-languages.zip
mv phpMyAdmin-*-all-languages phpmyadmin
rm -f phpMyAdmin-latest-all-languages.zip
mkdir -p /var/www/phpmyadmin/tmp
chown -R nobody:nobody /var/www/phpmyadmin
chmod -R 755 /var/www/phpmyadmin

# Configure phpMyAdmin
cat > /var/www/phpmyadmin/config.inc.php <<EOL
<?php
\$i = 0;
\$i++;
\$cfg['blowfish_secret'] = 'ChangeThisSecret123!@#';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['user'] = '$MYSQL_USER';
\$cfg['Servers'][\$i]['password'] = '$MYSQL_PASS';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
?>
EOL

# Download MITACP Panel
cd /var/www/
wget https://raw.githubusercontent.com/mitatag/mitacp/main/panel.zip
unzip panel.zip -d mitacp
rm -f panel.zip

# Configure MITACP Panel
cat > /var/www/mitacp/config.php <<EOL
<?php
\$db_host = 'localhost';
\$db_user = '$MYSQL_USER';
\$db_pass = '$MYSQL_PASS';
\$db_name = 'mitacp';
\$ADMIN_USER = '$ADMIN_USER';
\$ADMIN_PASS = password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);
?>
EOL
chown -R nobody:nobody /var/www/mitacp
chmod -R 755 /var/www/mitacp

# Install Tiny File Manager
mkdir -p /var/www/mitacp/files
cd /var/www/mitacp/files
wget https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php
echo "<?php \$auth_users = array('$ADMIN_USER' => '$ADMIN_PASS'); ?>" > config.php

# Setup Default VH and 404 page
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

# Configure VH for MITACP Panel on port 8088
mkdir -p /usr/local/lsws/conf/vhosts/mitacp
IP=$(curl -s https://ipinfo.io/ip)
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

# Open firewall ports
systemctl enable firewalld
systemctl start firewalld
firewall-cmd --permanent --add-port=8088/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --reload

# Restart OpenLiteSpeed
systemctl restart lsws

# Show installation info
echo "=== Installation Completed ==="
echo "MITACP Panel: http://$IP:8088"
echo "File Manager: http://$IP:8088/files/tinyfilemanager.php"
echo "phpMyAdmin: http://$IP/phpmyadmin"
echo "MySQL root username: $MYSQL_USER"
echo "MySQL root password: $MYSQL_PASS"
echo "Admin MITACP: $ADMIN_USER / Password: $ADMIN_PASS"
echo "Direct IP shows index page: http://$IP"
echo "Any undefined domain shows 404 page"
