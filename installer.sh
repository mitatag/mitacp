#!/bin/bash
# MITACP Full Installer - AlmaLinux 8
# OpenLiteSpeed + PHP7.4 + MariaDB + phpMyAdmin + MITACP Dashboard
set -euo pipefail

echo "=== Cleaning previous installations ==="
systemctl stop lsws || true
systemctl stop mariadb || true
dnf remove -y openlitespeed lsphp* mariadb* mysql* phpmyadmin || true
rm -rf /usr/local/lsws/Example/html/mitacp /usr/local/lsws/conf/vhosts/mitacp /var/www/phpmyadmin || true

echo "=== Installing dependencies ==="
dnf update -y
dnf install -y wget unzip curl epel-release git sudo firewalld

echo "=== Installing OpenLiteSpeed + PHP7.4 ==="
# استخدم مستودع LiteSpeed الرسمي الحديث
wget -O - https://repo.litespeed.sh | bash
dnf makecache
dnf install -y openlitespeed lsphp74 lsphp74-common lsphp74-mbstring lsphp74-mysqlnd lsphp74-pdo lsphp74-opcache lsphp74-process
systemctl enable --now lsws

echo "=== Installing MariaDB ==="
curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash
dnf install -y mariadb-server
systemctl enable --now mariadb

# Input admin + DB passwords
read -p "Enter MITACP admin username: " ADMIN_USER
read -sp "Enter MITACP admin password: " ADMIN_PASS
echo
read -sp "Enter MariaDB root password: " DB_ROOT_PASS
echo

# Setup MariaDB root
mariadb -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS'; FLUSH PRIVILEGES;"
mariadb -uroot -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS mitacp;"

# Setup MITACP folder
MITACP_DIR="/usr/local/lsws/Example/html/mitacp"
mkdir -p "$MITACP_DIR"
cd "$MITACP_DIR"

# Download MITACP files
wget https://raw.githubusercontent.com/mitatag/mitacp/main/index.php
wget https://raw.githubusercontent.com/mitatag/mitacp/main/domin.php

# Create db.php automatically
cat > db.php <<EOL
<?php
define("DB_HOST", "localhost");
define("DB_NAME", "mitacp");
define("DB_USER", "root");
define("DB_PASS", "$DB_ROOT_PASS");

\$ADMIN_USER = '$ADMIN_USER';
\$ADMIN_PASS = password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);

\$conn = new mysqli(DB_HOST, DB_USER, DB_PASS, DB_NAME);
if (\$conn->connect_error) {
    die("Connection failed: " . \$conn->connect_error);
}
?>
EOL

# phpMyAdmin
wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip
unzip phpMyAdmin-latest-all-languages.zip
mv phpMyAdmin-*-all-languages phpmyadmin
rm -f phpMyAdmin-latest-all-languages.zip
mkdir -p phpmyadmin/tmp
chown -R nobody:nobody phpmyadmin
chmod -R 755 phpmyadmin

# Tiny File Manager
mkdir -p files
cd files
wget https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php
echo "<?php \$auth_users = array('$ADMIN_USER' => '$ADMIN_PASS'); ?>" > config.php

# Virtual Host config for MITACP
IP=$(curl -s https://ipinfo.io/ip)
mkdir -p /usr/local/lsws/conf/vhosts/mitacp
cat > /usr/local/lsws/conf/vhosts/mitacp/vhost.conf <<EOL
docRoot $MITACP_DIR
vhDomain $IP
vhAliases *
adminEmails admin@example.com
enableGzip 1
errorlog \$SERVER_ROOT/logs/mitacp_error.log
accesslog \$SERVER_ROOT/logs/mitacp_access.log
index { useServer 0 indexFiles index.php }
EOL

# Firewall ports
systemctl enable --now firewalld
firewall-cmd --permanent --add-port=8088/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --reload

# Restart OpenLiteSpeed
systemctl restart lsws

# Finished
echo "=== Installation Completed ==="
echo "MITACP Dashboard: http://$IP:8088"
echo "phpMyAdmin: http://$IP:8088/phpmyadmin"
echo "File Manager: http://$IP:8088/files/tinyfilemanager.php"
echo "Admin Username: $ADMIN_USER"
echo "Admin Password: $ADMIN_PASS"
