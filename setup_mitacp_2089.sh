#!/bin/bash
# MITACP HTTPS Listener setup on port 2089 for LiteSpeed

SERVER_ROOT="/usr/local/lsws"
VHOST_NAME="MITACP_VHOST"
VHOST_ROOT="$SERVER_ROOT/Example/html/mitacp"
VHOST_CONF="$SERVER_ROOT/conf/vhosts/$VHOST_NAME/vhconf.conf"
HTTPD_CONF="$SERVER_ROOT/conf/httpd_config.xml"
LISTENER_NAME="mitacp_https"

echo "[1/5] Creating Virtual Host directory..."
mkdir -p "$SERVER_ROOT/conf/vhosts/$VHOST_NAME"

echo "[2/5] Creating vhconf.conf..."
cat > "$VHOST_CONF" <<EOL
virtualhost $VHOST_NAME {
    vhRoot                  $VHOST_ROOT
    configFile              conf/vhosts/$VHOST_NAME/vhconf.conf
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

echo "[3/5] Adding Listener to httpd_config.xml..."
# تحقق من عدم وجود Listener مسبقًا
grep -q "$LISTENER_NAME" "$HTTPD_CONF"
if [ $? -ne 0 ]; then
cat >> "$HTTPD_CONF" <<EOL

listener $LISTENER_NAME {
    address                 *:2089
    secure                  1
    keyFile                 \$SERVER_ROOT/admin/conf/webadmin.key
    certFile                \$SERVER_ROOT/admin/conf/webadmin.crt
    map                     $VHOST_NAME *
}
EOL
else
    echo "Listener $LISTENER_NAME موجود بالفعل في httpd_config.xml"
fi

echo "[4/5] Opening firewall port 2089..."
sudo firewall-cmd --permanent --add-port=2089/tcp
sudo firewall-cmd --reload

echo "[5/5] Restarting LiteSpeed..."
sudo $SERVER_ROOT/bin/lswsctrl restart

echo "✅ MITACP Listener setup on port 2089 completed!"
echo "Open https://<IP>:2089/ to access your MITACP panel"
