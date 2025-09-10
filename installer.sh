# تحديث النظام
dnf update -y

# تثبيت المستلزمات الأساسية
dnf install wget unzip curl epel-release git sudo -y

# تثبيت مستودع LiteSpeed
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.1-1.el8.noarch.rpm || echo "Repo already installed"

# تثبيت OpenLiteSpeed
dnf install openlitespeed -y

# تثبيت PHP 7.4 مع الحزم الصحيحة
dnf install lsphp74 lsphp74-common lsphp74-xml lsphp74-mbstring lsphp74-mysqli lsphp74-pdo_mysql -y

# تمكين وتشغيل OpenLiteSpeed
systemctl enable lsws
systemctl start lsws

# تثبيت MariaDB
dnf install mariadb-server -y
systemctl enable mariadb
systemctl start mariadb

# إعداد MariaDB الأساسي (سيطلب كلمة مرور root)
mysql_secure_installation

# إنشاء قاعدة بيانات MITACP
mysql -uroot -p -e "CREATE DATABASE IF NOT EXISTS mitacp;"

# تثبيت phpMyAdmin
dnf install phpmyadmin -y

# تنزيل ملفات لوحة MITACP
cd /var/www/
wget https://raw.githubusercontent.com/mitatag/mitacp/main/panel.zip
unzip panel.zip -d mitacp
rm -f panel.zip

# إعداد config.php للوحة
ADMIN_USER="admin"
ADMIN_PASS="admin123456"
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

# أذونات الملفات
chown -R nobody:nobody /var/www/mitacp
chmod -R 755 /var/www/mitacp

# تثبيت Tiny File Manager داخل اللوحة
cd /var/www/mitacp
mkdir -p files
cd files
wget https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php
echo "<?php
\$auth_users = array('$ADMIN_USER' => '$ADMIN_PASS');
?>" > config.php

# تثبيت acme.sh لإصدار SSL مجاني
curl https://get.acme.sh | sh

# فتح البورتات الأساسية في firewalld
systemctl enable firewalld
systemctl start firewalld
firewall-cmd --permanent --add-port=8088/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --reload

# إعداد Virtual Host افتراضي لـ MITACP
mkdir -p /usr/local/lsws/conf/vhosts/mitacp
cat > /usr/local/lsws/conf/vhosts/mitacp/vhost.conf <<EOL
docRoot                   /var/www/mitacp
vhDomain                   $(curl -s https://ipinfo.io/ip)
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

# إعادة تشغيل OpenLiteSpeed
systemctl restart lsws

echo "=== التثبيت اكتمل ==="
echo "لوحة MITACP جاهزة:"
echo "رابط الدخول: http://$(curl -s https://ipinfo.io/ip):8088"
echo "Admin: $ADMIN_USER / Password: $ADMIN_PASS"
echo "مدير الملفات متاح هنا: http://$(curl -s https://ipinfo.io/ip):8088/files/tinyfilemanager.php"
