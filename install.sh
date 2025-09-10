#!/bin/bash
# MITA Sentora OpenLiteSpeed Installer
# AlmaLinux / Rocky Linux / CentOS 8+

# 1️⃣ تثبيت OpenLiteSpeed و PHP
echo "🔹 Installing OpenLiteSpeed and PHP..."
dnf install -y https://rpms.litespeedtech.com/centos/litespeed-repo-1.1-1.el8.noarch.rpm
dnf install -y openlitespeed lsphp74 lsphp74-mysqlnd lsphp74-common lsphp74-process lsphp74-mbstring lsphp74-gd lsphp74-xml lsphp74-curl

systemctl enable lsws
systemctl start lsws

# 2️⃣ تنزيل Sentora Core
echo "🔹 Cloning Sentora Core..."
cd /usr/local/lsws/Example/html || exit
git clone https://github.com/sentora/sentora-core.git sentora
cd sentora || exit

# 3️⃣ ضبط قواعد إعادة الكتابة OpenLiteSpeed
echo "🔹 Configuring rewrite rules..."
REWRITE_FILE="/usr/local/lsws/conf/vhosts/Example/rewrite.conf"
mkdir -p $(dirname $REWRITE_FILE)
cat > $REWRITE_FILE <<EOL
RewriteEngine On
RewriteRule ^admin/(.*)$ admin/index.php?route=\$1 [L,QSA]
RewriteRule ^client/(.*)$ client/index.php?route=\$1 [L,QSA]
EOL

# تأكد من تفعيل Rewrite في Virtual Host من لوحة OpenLiteSpeed
echo "✅ Rewrite rules saved at $REWRITE_FILE. Enable rewrite in OpenLiteSpeed admin panel if not already."

# 4️⃣ إنشاء قاعدة بيانات
DB_NAME="sentora_db"
DB_USER="sentora_user"
DB_PASS="password"

echo "🔹 Creating MariaDB database..."
mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

echo "✅ Database created: $DB_NAME / User: $DB_USER"

# 5️⃣ ضبط config.php
CONFIG_FILE="includes/config.php"
if [ -f "$CONFIG_FILE" ]; then
    sed -i "s/'DB_NAME'.*/'DB_NAME', '$DB_NAME');/" $CONFIG_FILE
    sed -i "s/'DB_USER'.*/'DB_USER', '$DB_USER');/" $CONFIG_FILE
    sed -i "s/'DB_PASS'.*/'DB_PASS', '$DB_PASS');/" $CONFIG_FILE
    echo "✅ config.php updated with DB credentials"
fi

echo "🎉 Installation complete! Open http://your-server/sentora/admin to login (default admin/password)."
