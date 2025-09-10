#!/bin/bash

# إنشاء مجلد Virtual Host لو مش موجود
sudo mkdir -p $SERVER_ROOT/conf/vhosts/MITACP_VHOST
sudo mkdir -p /usr/local/lsws/Example/html/mitacp/logs

# إنشاء ملف vhconf.conf
sudo tee $SERVER_ROOT/conf/vhosts/MITACP_VHOST/vhconf.conf > /dev/null <<EOL
virtualhost MITACP_VHOST {
    vhRoot                  /usr/local/lsws/Example/html/mitacp
    configFile              conf/vhosts/MITACP_VHOST/vhconf.conf
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

# تحميل الملفات من GitHub
wget -P /usr/local/lsws/Example/html/mitacp https://raw.githubusercontent.com/mitatag/mitacp/main/setup_mitacp_2089.sh

# أعطِ صلاحيات تنفيذ للسكريبت
chmod +x /usr/local/lsws/Example/html/mitacp/setup_mitacp_2089.sh

echo "تم إنشاء vhconf.conf وتحميل السكريبت."
