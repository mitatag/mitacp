#!/bin/bash
# MITACP Full Installer - OpenLiteSpeed + PHP7.4 + MySQL8 + MITACP + phpMyAdmin
# Only enter usernames and passwords when prompted
# All other settings are fixed

set -euo pipefail

# -----------------------
# Cleaning previous installations
# -----------------------
echo "=== Cleaning previous installations ==="
systemctl stop lsws || true
systemctl stop mariadb || true
systemctl stop mysqld || true

dnf remove -y openlitespeed lsphp* mariadb* mysql* phpmyadmin || true
rm -rf /var/www/mitacp /var/www/phpmyadmin /usr/local/lsws/* /var/log/mariadb /var/log/mysql || true

# -----------------------
# Enter user input
# -----------------------
read -p "Enter MITACP admin username: " ADMIN_USER
read -s -p "Enter MITACP admin password: " ADMIN_PASS
echo
read -s -p "Enter MySQL root password: " DB_ROOT_PASS
echo

# -----------------------
# Install required packages
# -----------------------
dnf update -y
dnf install -y wget unzip curl epel-release git sudo dnf-plugins-core

# -----------------------
# Install LiteSpeed
# -----------------------
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.2-1.el8.noarch.rpm || echo "Repo already installed"
dnf install -y openlitespeed lsphp74 lsphp74-common lsphp74-mbstring lsphp74-xml lsphp74-mysqlnd

systemctl enable lsws
systemctl start lsws

# -----------------------
# Install MySQL 8.0
# -----------------------
wget https://repo.mysql.com/mysql80-community-release-el8-3.noarch.rpm
dnf localinstall -y mysql80-community-release-el8-3.noarch.rpm
dnf config-manager --enable mysql80-community
dnf makecache
dnf install -y mysql-community-server

systemctl enable mysqld
systemctl start mysqld

# Set MySQL root password
mysql --connect-expired-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS'; FLUSH PRIVILEGES;"

# -----------------------
# Create MITACP database
# -----------------------
mysql -uroot -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS mitacp;"

# -----------------------
# Install phpMyAdmin
# -----------------------
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

# -----------------------
# Install MITACP
# -----------------------
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

# -----------------------
# Install Tiny File Manager
# -----------------------
mkdir -p /var/www/mitacp/files
cd /var/www/mitacp/files
wget https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php
echo "<?php \$auth_users = array('$ADMIN_USER' => '$ADMIN_PASS'); ?>" > config.php

# -----------------------
# Setup Default VH
# -----------------------
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

IP=$(curl -s https://ipinfo.io/ip)
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

# -----------------------
# Firewall
# -----------------------
systemctl enable firewalld
systemctl start firewalld
firewall-cmd --permanent --add-port=8088/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --reload

# -----------------------
# Restart OpenLiteSpeed
# -----------------------
systemctl restart lsws

# -----------------------
# Installation complete
# -----------------------
echo "=== Installation Complete ==="
echo "MITACP Panel: http://$IP:8088"
echo "File Manager: http://$IP:8088/files/tinyfilemanager.php"
echo "phpMyAdmin: http://$IP/phpmyadmin"
echo "MySQL root password: $DB_ROOT_PASS"
echo "Admin MITACP: $ADMIN_USER / Password: $ADMIN_PASS"
echo "Direct IP index page: http://$IP"
echo "Any undefined domain shows 404 page"
