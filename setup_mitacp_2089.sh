#!/bin/bash

# تأكد أنك تعمل بصلاحيات root
if [[ $EUID -ne 0 ]]; then
   echo "رجاءً شغّل السكريبت كـ root"
   exit 1
fi

# مسارات
SERVER_ROOT=/usr/local/lsws
VH_NAME=MITACP_VHOST
VH_ROOT=/usr/local/lsws/Example/html/mitacp

# إنشاء المجلدات اللازمة
mkdir -p $SERVER_ROOT/conf/vhosts/$VH_NAME
mkdir -p $VH_ROOT/logs

# إنشاء ملف vhconf.conf
tee $SERVER_ROOT/conf/vhosts/$VH_NAME/vhconf.conf > /dev/null <<EOL
virtualhost $VH_NAME {
    vhRoot                  $VH_ROOT
    configFile              conf/vhosts/$VH_NAME/vhconf.conf
    allowSymbolLink         1
    enableScript            1
    restrained              1

    index {
        indexFiles index.php,index.html
        autoIndex 0
    }

    accessLog \$VH_ROOT/logs/access.log
    errorlog \$VH_ROOT/logs/error.log
}
EOL

# إضافة Listener للـ MITACP على بورت 2089
tee -a $SERVER_ROOT/conf/httpd_config.xml > /dev/null <<EOL

listener mitacp_https {
    address                 *:2089
    reusePort               1
    secure                  1
    keyFile                 \$SERVER_ROOT/admin/conf/webadmin.key
    certFile                \$SERVER_ROOT/admin/conf/webadmin.crt
    map                     $VH_NAME *
}
EOL

# تحميل سكريبت إعداد MITACP
wget -P $VH_ROOT https://raw.githubusercontent.com/mitatag/mitacp/main/setup_mitacp_2089.sh
chmod +x $VH_ROOT/setup_mitacp_2089.sh

# إعادة تشغيل LiteSpeed
$SERVER_ROOT/bin/lswsctrl restart

echo "✅ تم إعداد Virtual Host و Listener على بورت 2089 بنجاح."
echo "الآن يمكنك الوصول إلى: https://IP:2089/"
