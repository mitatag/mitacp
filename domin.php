<?php
require_once "db.php";
session_start();
if (!isset($_SESSION['admin_logged']) || $_SESSION['admin_logged'] !== true) {
    header("Location: index.php");
    exit;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $domain = trim($_POST['domain']);
    $docroot = "/home/$domain/public_html";

    // إنشاء مجلد الموقع
    if (!file_exists($docroot)) {
        mkdir($docroot, 0755, true);
    }

    // إعداد Virtual Host
    $vh_conf = "/usr/local/lsws/conf/vhosts/$domain/vhost.conf";
    mkdir(dirname($vh_conf), 0755, true);
    $conf = <<<EOL
docRoot $docroot
vhDomain $domain
vhAliases *
adminEmails admin@example.com
enableGzip 1
errorlog \$SERVER_ROOT/logs/{$domain}_error.log
accesslog \$SERVER_ROOT/logs/{$domain}_access.log
index { useServer 0 indexFiles index.html }
EOL;

    file_put_contents($vh_conf, $conf);

    // إضافة Mapping
    $map_conf = "/usr/local/lsws/conf/httpd_config.conf";
    if (file_exists($map_conf)) {
        file_put_contents($map_conf, "\nvirtualHost $domain $domain\n", FILE_APPEND);
    }

    // Reload OpenLiteSpeed
    shell_exec("systemctl restart lsws");

    echo "<p>تم إنشاء الدومين بنجاح: $domain</p>";
}
?>

<h2>إضافة دومين جديد</h2>
<form method="POST">
    <input type="text" name="domain" placeholder="example.com" required>
    <button type="submit">إنشاء الدومين</button>
</form>
