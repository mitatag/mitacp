#!/bin/bash

# إعدادات المسارات
VH_NAME="MITACP_VHOST"
VH_ROOT="/usr/local/lsws/$VH_NAME/html/mitacp"
CONFIG_FILE="$SERVER_ROOT/conf/vhosts/$VH_NAME/vhconf.conf"
LISTENER_NAME="mitacp_https"
LISTENER_PORT="2089"
SSL_KEY="$SERVER_ROOT/admin/conf/webadmin.key"
SSL_CERT="$SERVER_ROOT/admin/conf/webadmin.crt"

# إنشاء مجلد الـ Virtual Host
mkdir -p "$VH_ROOT"

# إنشاء ملف vhconf.conf
cat > "$CONFIG_FILE" <<EOF
virtualhost $VH_NAME {
    vhRoot                  $VH_ROOT
    configFile              $CONFIG_FILE
    allowSymbolLink         1
    enableScript            1
    restrained              1

    index {
        indexFiles index.php,index.html
        autoIndex 0
    }

    errorPage 404 {
        url /error404.html
    }

    accessLog $VH_ROOT/logs/access.log {
        rollingSize 10M
        keepDays 30
    }

    errorlog $VH_ROOT/logs/error.log {
        logLevel DEBUG
        rollingSize 10M
    }
}

listener $LISTENER_NAME {
    address                 *:$LISTENER_PORT
    secure                  1
    keyFile                 $SSL_KEY
    certFile                $SSL_CERT
    map                     $VH_NAME *
}
EOF

# تحديث إعدادات LiteSpeed
echo "include $CONFIG_FILE" >> "$SERVER_ROOT/conf/httpd_config.xml"

# إعادة تشغيل LiteSpeed لتطبيق التغييرات
sudo /usr/local/lsws/bin/lswsctrl restart

echo "تم إعداد Virtual Host وListener بنجاح على البورت $LISTENER_PORT."
