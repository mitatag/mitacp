#!/bin/bash

# إعداد متغيرات
SERVER_ROOT="/usr/local/lsws"
VHOST_NAME="MITACP_VHOST"
VHOST_ROOT="$SERVER_ROOT/Example/html/mitacp"
VHOST_CONF_DIR="$SERVER_ROOT/conf/vhosts/$VHOST_NAME"
VHOST_CONF_FILE="$VHOST_CONF_DIR/vhconf.conf"
HTTPD_CONFIG="$SERVER_ROOT/conf/httpd_config.xml"

# إنشاء مجلد Virtual Host إذا لم يكن موجود
mkdir -p "$VHOST_CONF_DIR/logs"

# إنشاء ملف vhconf.conf
cat > "$VHOST_CONF_FILE" <<EOL
virtualhost $VHOST_NAME {
    vhRoot                  $VHOST_ROOT
    configFile              $VHOST_CONF_FILE
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

    accessLog \$VH_ROOT/logs/access.log {
        rollingSize 10M
        keepDays 30
    }

    errorlog \$VH_ROOT/logs/error.log {
        logLevel DEBUG
        rollingSize 10M
    }
}
EOL

echo "تم إنشاء ملف vhconf.conf في $VHOST_CONF_FILE"

# إضافة Listener للـ HTTPS بورت 2089
cat >> "$HTTPD_CONFIG" <<EOL

listener mitacp_https {
    address                 *:2089
    secure                  1
    keyFile                 \$SERVER_ROOT/admin/conf/webadmin.key
    certFile                \$SERVER_ROOT/admin/conf/webadmin.crt
    map                     $VHOST_NAME *
}
EOL

echo "تم إعداد Listener على بورت 2089"

# إعادة تشغيل LiteSpeed
$SERVER_ROOT/bin/lswsctrl restart
echo "تم إعادة تشغيل LiteSpeed بنجاح!"
