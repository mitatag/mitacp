#!/bin/bash
# MITACP Installer for AlmaLinux 8 / Rocky Linux 8
# OpenLiteSpeed + PHP7.4 + MySQL 8.0 + MITACP + phpMyAdmin

set -euo pipefail

#-----------------------
# Cleanup previous installations
#-----------------------
echo "=== Cleaning previous installations ==="
systemctl stop lsws || true
systemctl stop mysqld || true

dnf remove -y openlitespeed lsphp74* mysql-community-server phpmyadmin || true
rm -rf /var/www/mitacp /var/www/phpmyadmin /usr/local/lsws/DEFAULT/html
rm -rf /var/log/mariadb /var/log/mysql || true

#-----------------------
# Ask user for credentials
#-----------------------
read -p "Enter MITACP admin username: " ADMIN_USER
read -sp "Enter MITACP admin password: " ADMIN_PASS
echo
read -sp "Enter MySQL root password: " DB_ROOT_PASS
echo

IP=$(curl -s https://ipinfo.io/ip)

#-----------------------
# Install dependencies
#-----------------------
dnf update -y
dnf install wget unzip curl epel-release git sudo -y

#-----------------------
# Install LiteSpeed + PHP 7.4
#-----------------------
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.1-1.el8.noarch.rpm || echo "Repo already installed"
dnf install -y openlitespeed lsphp74 lsphp74-common lsphp74-xml lsphp74-mbstring lsphp74-mysqli lsphp74-pdo_mysql
systemctl enable lsws
systemctl start lsws

#-----------------------
# Install MySQL 8.0
#-----------------------
wget https://dev.mysql.com/get/mysql80-community-release-el8-3.noarch.rpm
dnf localinstall -y mysql80-community-release-el8-3.noarch.rpm
dnf config-manager --disable mysql80-community-source
dnf install -y mysql-community-server
systemctl enable mysqld
systemctl start mysqld

# Set root password
mysql --connect-expired-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS'; FLUSH PRIVILEGES;"

#-----------------------
# Create MITACP database
#-----------------------
mysql -uroot -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS mitacp;"

#-----------------------
# Download phpMyAdmin
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
# Download MITACP panel
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
# Tiny File Manager
#-----------------------
mkdir -p /var/www/mitacp/files
cd /var/www/mitacp/files
wget https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php
echo "<?php \$auth_users = array('$ADMIN_USER' => '$ADMIN_PASS'); ?>" > config.php

#-----------------------
# Default VH
#-----------------------
mkdir -p /usr/local/lsws/DEFAULT/html
echo "<!DOCTYPE html>
<html>
<head><title>Welcome to LiteSpeed</title></head>
<body>
<h1>Welcome to LiteSpeed Web Server!</h1>
</body>
</html>" > /usr/local/lsws/DEFAULT/html/index.html

echo "<!DOCTYPE html>
<html>
<head><title>404 Not Found</title></head>
<body>
<h1>404 Not Found</h1>
<p>The requested URL was not found on this server.</p>
</body>
</html>" > /usr/local/lsws/DEFAULT/html/404.html

#-----------------------
# Firewall
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
# Show installation info
#-----------------------
echo "=== Installation Complete ==="
echo "MITACP Panel: http://$IP:8088"
echo "File Manager: http://$IP:8088/files/tinyfilemanager.php"
echo "phpMyAdmin: http://$IP/phpmyadmin"
echo "MySQL root password: $DB_ROOT_PASS"
echo "Admin MITACP: $ADMIN_USER / Password: $ADMIN_PASS"
echo "IP direct index: http://$IP"
echo "Any unknown domain shows 404 page"
