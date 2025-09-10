#!/bin/bash

# تعريف SERVER_ROOT الصحيح
SERVER_ROOT="/usr/local/lsws"

# إعدادات المسارات
VH_NAME="MITACP_VHOST"
VH_ROOT="$SERVER_ROOT/$VH_NAME/html/mitacp"
CONFIG_DIR="$SERVER_ROOT/conf/vhosts/$VH_NAME"
CONFIG_FILE="$CONFIG_DIR/vhconf.conf"
LISTENER_NAME="mitacp_https"
LISTENER_PORT="2089"
SSL_KEY="$SERVER_ROOT/admin/conf/webadmin.key"
SSL_CERT="$SERVER_ROOT/admin/conf/webadmin.crt"

# إنشاء مجلدات Virtual Host
mkdir -p "$VH_ROOT" "$CONFIG_DIR" "$VH_ROOT/logs"

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

# إضافة الـ include في httpd_config.xml إذا لم يكن موجود
if ! grep -q "$CONFIG_FILE" "$SERVER_ROOT/conf/httpd_config.xml"; then
    sed -i "/<\/config>/i \    include $CONFIG_FILE" "$SERVER_ROOT/conf/httpd_config.xml"
fi

# إعادة تشغيل LiteSpeed
sudo $SERVER_ROOT/bin/lswsctrl restart

echo "تم إعداد Virtual Host وListener بنجاح على البورت $LISTENER_PORT."
