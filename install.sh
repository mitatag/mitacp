#!/bin/bash
# MITACP full installer for AlmaLinux (OpenLiteSpeed + PHP 7.4 + MariaDB + phpMyAdmin + Mini Panel)
# Panel language: English only
# Panel features: add site, create DB, import SQL, manage sites, list DBs, file manager (basic edit/save), LiteSpeed tools (restart/status/reload), issue Let's Encrypt via acme.sh
# Default admin: admin / admin123456 (changeable from the panel)

set -euo pipefail
ROOT_WEBROOT="/usr/local/lsws/Example/html"
PANEL_DIR="$ROOT_WEBROOT/mitacp"
HELPER_DIR="/usr/local/mitacp/bin"
ENV_FILE="/etc/mitacp.env"
SUDOERS_FILE="/etc/sudoers.d/mitacp_helpers"

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

echo "\n==> MITACP installer starting..."

# 1) Update system
dnf -y update

# 2) Install prerequisites
dnf -y install epel-release
dnf -y install wget curl unzip tar git sudo nmap-ncat httpd-tools openssl

# 3) Add LiteSpeed repo and install OpenLiteSpeed
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.2-1.el8.noarch.rpm || true
dnf makecache
dnf -y install openlitespeed

# 4) Install PHP 7.4 (lsphp74) and common modules
dnf -y install lsphp74 lsphp74-mysqlnd lsphp74-common lsphp74-gd lsphp74-mbstring lsphp74-opcache lsphp74-xml lsphp74-zip

# 5) Install MariaDB
dnf -y install mariadb-server mariadb
systemctl enable --now mariadb

# 6) Ask user for MariaDB root password (or auto-generate)
read -p "Enter desired MariaDB root password (leave empty to auto-generate): " MYSQL_ROOT_PASSWORD
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
  MYSQL_ROOT_PASSWORD=$(openssl rand -base64 12)
  echo "Generated MariaDB root password: $MYSQL_ROOT_PASSWORD"
fi

# 7) Secure MariaDB & set root password
systemctl restart mariadb
sleep 2
mysql --user=root <<SQL || true
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
SQL

# Save env file for helper scripts
cat > "$ENV_FILE" <<EOF
# MITACP environment
MYSQL_ROOT_PASSWORD='${MYSQL_ROOT_PASSWORD}'
EOF
chmod 600 "$ENV_FILE"

# 8) Install phpMyAdmin into webroot
mkdir -p "$ROOT_WEBROOT"
cd /tmp
PMA_URL="https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz"
wget -q "$PMA_URL" -O /tmp/phpmyadmin.tar.gz
tar xzf /tmp/phpmyadmin.tar.gz -C /tmp
PMA_DIR=$(ls -d /tmp/phpMyAdmin-*-all-languages | head -n1)
rm -rf "$ROOT_WEBROOT/phpmyadmin" || true
mv "$PMA_DIR" "$ROOT_WEBROOT/phpmyadmin"
chown -R nobody:nobody "$ROOT_WEBROOT/phpmyadmin" || true
rm -f /tmp/phpmyadmin.tar.gz

# 9) Install acme.sh for Let's Encrypt (will be used by issue_ssl helper)
curl https://get.acme.sh | sh -s -- --install --nocron
ACME_SH="/root/.acme.sh/acme.sh"

# 10) Create helper scripts
mkdir -p "$HELPER_DIR"
cat > "$HELPER_DIR/addsite.sh" <<'BASH'
#!/bin/bash
# usage: addsite.sh domain dbname dbuser dbpass auto_ssl
set -e
. /etc/mitacp.env
DOMAIN="$1"
DBNAME="$2"
DBUSER="$3"
DBPASS="$4"
AUTO_SSL="$5"
ROOT="/var/www/$DOMAIN/public_html"
# create folders
mkdir -p "$ROOT"
chown -R nobody:nobody "$ROOT" || chown -R $(whoami):$(whoami) "$ROOT" 2>/dev/null || true
chmod -R 755 "$ROOT"
# default index
cat > "$ROOT/index.php" <<PHP
<?php
http_response_code(200);
echo "<h1>Welcome to $DOMAIN</h1>";
?>
PHP
# create symlink into OLS example html so it's served
ln -s "$ROOT" "/usr/local/lsws/Example/html/$DOMAIN" 2>/dev/null || true
# create database if requested
if [ -n "$DBNAME" ]; then
  mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`;"
fi
if [ -n "$DBUSER" ] && [ -n "$DBPASS" ]; then
  mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS'; GRANT ALL PRIVILEGES ON \`$DBNAME\`.* TO '$DBUSER'@'localhost'; FLUSH PRIVILEGES;"
fi
# restart OLS to pick changes
/usr/local/lsws/bin/lswsctrl restart || true
# optionally issue SSL if requested
if [ "$AUTO_SSL" = "1" ]; then
  /root/.acme.sh/acme.sh --issue -d "$DOMAIN" -w "$ROOT" --force || true
  mkdir -p /etc/ssl/mitacp/$DOMAIN
  /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file /etc/ssl/mitacp/$DOMAIN/$DOMAIN.key --fullchain-file /etc/ssl/mitacp/$DOMAIN/$DOMAIN.crt --reloadcmd "/usr/local/lsws/bin/lswsctrl restart" || true
fi

echo "OK"
BASH

cat > "$HELPER_DIR/createdb.sh" <<'BASH'
#!/bin/bash
# usage: createdb.sh dbname dbuser dbpass
set -e
. /etc/mitacp.env
DBNAME="$1"
DBUSER="$2"
DBPASS="$3"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`;"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS'; GRANT ALL PRIVILEGES ON \`$DBNAME\`.* TO '$DBUSER'@'localhost'; FLUSH PRIVILEGES;"
echo "OK"
BASH

cat > "$HELPER_DIR/importsql.sh" <<'BASH'
#!/bin/bash
# usage: importsql.sh dbname sqlfile
set -e
. /etc/mitacp.env
DBNAME="$1"
SQLFILE="$2"
if [ ! -f "$SQLFILE" ]; then
  echo "SQL file not found"; exit 1
fi
mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$DBNAME" < "$SQLFILE"
echo "OK"
BASH

cat > "$HELPER_DIR/listdbs.sh" <<'BASH'
#!/bin/bash
set -e
. /etc/mitacp.env
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;"
BASH

cat > "$HELPER_DIR/issue_ssl.sh" <<'BASH'
#!/bin/bash
# usage: issue_ssl.sh domain
set -e
. /etc/mitacp.env
DOMAIN="$1"
WEBROOT="/var/www/$DOMAIN/public_html"
if [ -z "$DOMAIN" ]; then echo "Domain required"; exit 1; fi
if [ ! -d "$WEBROOT" ]; then echo "Webroot not found: $WEBROOT"; exit 1; fi
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" -w "$WEBROOT" --force
mkdir -p /etc/ssl/mitacp/$DOMAIN
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/ssl/mitacp/$DOMAIN/$DOMAIN.key \
  --fullchain-file /etc/ssl/mitacp/$DOMAIN/$DOMAIN.crt \
  --reloadcmd "/usr/local/lsws/bin/lswsctrl restart"
echo "OK"
BASH

cat > "$HELPER_DIR/file_write.sh" <<'BASH'
#!/bin/bash
# usage: file_write.sh /full/path/to/file base64_content
set -e
FILE="$1"
CONTENT_B64="$2"
mkdir -p "$(dirname "$FILE")"
echo "$CONTENT_B64" | base64 -d > "$FILE"
chown nobody:nobody "$FILE" 2>/dev/null || true
chmod 644 "$FILE"
echo "OK"
BASH

chmod +x $HELPER_DIR/*.sh

# 11) Create sudoers entry for nobody to run helper scripts (restricted)
cat > "$SUDOERS_FILE" <<EOF
# MITACP helper scripts (allowed without password)
nobody ALL=(ALL) NOPASSWD: $HELPER_DIR/addsite.sh, $HELPER_DIR/createdb.sh, $HELPER_DIR/importsql.sh, $HELPER_DIR/listdbs.sh, $HELPER_DIR/issue_ssl.sh, $HELPER_DIR/file_write.sh
EOF
chmod 440 "$SUDOERS_FILE"

# 12) Create MITACP panel files (English)
mkdir -p "$PANEL_DIR"

# admin.json default credentials
cat > "$PANEL_DIR/admin.json" <<EOF
{
  "user": "admin",
  "pass": "admin123456"
}
EOF
chmod 600 "$PANEL_DIR/admin.json"
chown -R nobody:nobody "$PANEL_DIR" 2>/dev/null || true

# header.php (English)
cat > "$PANEL_DIR/header.php" <<'PHP'
<?php
function mitacp_header(){
  echo '<div style="background:#2b6cb0; padding:12px; color:#fff; display:flex; justify-content:space-between; align-items:center;">';
  echo '<div style="font-weight:bold; font-size:18px;">mitacp</div>';
  echo '<div><a href="?theme=toggle" style="color:#fff;">Toggle Theme</a></div>';
  echo '</div>';
}
?>
PHP

# footer.php (English)
cat > "$PANEL_DIR/footer.php" <<'PHP'
<?php
function mitacp_footer(){
  echo '<div style="text-align:center;padding:12px;color:#666;margin-top:20px;">All rights reserved &copy; mitacp - mitatag.com</div>';
}
?>
PHP

# auth.php (English)
cat > "$PANEL_DIR/auth.php" <<'PHP'
<?php
session_start();
$adminFile = __DIR__.'/admin.json';
$creds = json_decode(file_get_contents($adminFile), true);
$ADMIN_USER = $creds['user'];
$ADMIN_PASS = $creds['pass'];
if (!isset($_SESSION['loggedin']) || $_SESSION['loggedin'] !== true) {
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['username'])) {
        if ($_POST['username'] === $ADMIN_USER && $_POST['password'] === $ADMIN_PASS) {
            $_SESSION['loggedin'] = true;
        } else {
            echo '<div style="color:red;">Invalid credentials</div>';
        }
    }
    if (!isset($_SESSION['loggedin']) || $_SESSION['loggedin'] !== true) {
        echo '<h3>Login to mitacp</h3>';
        echo '<form method="post">';
        echo 'Username: <input name="username"><br>';
        echo 'Password: <input type="password" name="password"><br>';
        echo '<button type="submit">Login</button>';
        echo '</form>';
        exit;
    }
}
?>
PHP

# index.php (English)
cat > "$PANEL_DIR/index.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header(); ?>
<div style="padding:20px;">
  <h2>MITACP - Mini Control Panel</h2>
  <ul>
    <li><a href="addsite.php">Add Site</a></li>
    <li><a href="adddb.php">Add Database</a></li>
    <li><a href="sites.php">Manage Sites</a></li>
    <li><a href="dbs.php">Manage Databases</a></li>
    <li><a href="uploadsql.php">Import SQL</a></li>
    <li><a href="filemanager.php">File Manager</a></li>
    <li><a href="litespeed.php">LiteSpeed Tools</a></li>
    <li><a href="phpmyadmin.php">phpMyAdmin</a></li>
    <li><a href="change_admin.php">Change Admin Credentials</a></li>
  </ul>
</div>
<?php mitacp_footer(); ?>
PHP

# addsite.php (English panel)
cat > "$PANEL_DIR/addsite.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if($_SERVER['REQUEST_METHOD']=='POST'){
  $domain=trim($_POST['domain']);
  $dbname=trim($_POST['dbname']);
  $dbuser=trim($_POST['dbuser']);
  $dbpass=trim($_POST['dbpass']);
  $auto_ssl = isset($_POST['auto_ssl']) ? '1' : '0';
  $cmd = escapeshellcmd("sudo $HELPER_DIR/addsite.sh ") . ' ' . escapeshellarg($domain) . ' ' . escapeshellarg($dbname) . ' ' . escapeshellarg($dbuser) . ' ' . escapeshellarg($dbpass) . ' ' . escapeshellarg($auto_ssl);
  $out = shell_exec($cmd);
  echo '<div style="background:#e7ffe7;padding:10px;margin:10px 0;">'.htmlspecialchars($out).'</div>';
}
?>
<form method="post">
Domain: <input name="domain"><br>
Database (optional): <input name="dbname"><br>
DB User: <input name="dbuser"><br>
DB Pass: <input name="dbpass"><br>
Auto issue SSL (Let's Encrypt): <input type="checkbox" name="auto_ssl" value="1"><br>
<button type="submit">Create Site</button>
</form>
<?php mitacp_footer(); ?>
PHP

# adddb.php
cat > "$PANEL_DIR/adddb.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if($_SERVER['REQUEST_METHOD']=='POST'){
  $dbname=$_POST['dbname']; $dbuser=$_POST['dbuser']; $dbpass=$_POST['dbpass'];
  $cmd = "sudo $HELPER_DIR/createdb.sh " . escapeshellarg($dbname) . ' ' . escapeshellarg($dbuser) . ' ' . escapeshellarg($dbpass);
  $out = shell_exec($cmd);
  echo '<div style="background:#e7ffe7;padding:10px;margin:10px 0;">'.htmlspecialchars($out).'</div>';
}
?>
<form method="post">
DB Name: <input name="dbname"><br>
DB User: <input name="dbuser"><br>
DB Pass: <input name="dbpass"><br>
<button type="submit">Create DB</button>
</form>
<?php mitacp_footer(); ?>
PHP

# sites.php
cat > "$PANEL_DIR/sites.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
$sites = glob('/var/www/*', GLOB_ONLYDIR);
echo '<h3>Sites</h3><ul>';
foreach($sites as $s){
  $d = basename($s);
  echo '<li>'.htmlspecialchars($d).' - <a href="http://'.htmlspecialchars($d).'" target="_blank">Open</a> - <a href="litespeed.php?issue=' . urlencode($d) . '">Issue SSL</a></li>';
}
echo '</ul>';
mitacp_footer();
?>
PHP

# dbs.php
cat > "$PANEL_DIR/dbs.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
$out = shell_exec('sudo $HELPER_DIR/listdbs.sh');
echo '<pre>'.htmlspecialchars($out).'</pre>';
mitacp_footer();
?>
PHP

# uploadsql.php
cat > "$PANEL_DIR/uploadsql.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if($_SERVER['REQUEST_METHOD']=='POST' && isset($_FILES['sqlfile'])){
  $dbname = $_POST['dbname'];
  $tmp = $_FILES['sqlfile']['tmp_name'];
  $target = '/tmp/'.basename($_FILES['sqlfile']['name']);
  move_uploaded_file($tmp, $target);
  $cmd = "sudo $HELPER_DIR/importsql.sh " . escapeshellarg($dbname) . ' ' . escapeshellarg($target);
  $out = shell_exec($cmd);
  echo '<div style="background:#e7ffe7;padding:10px;margin:10px 0;">'.htmlspecialchars($out).'</div>';
}
?>
<form method="post" enctype="multipart/form-data">
DB Name: <input name="dbname"><br>
SQL File: <input type="file" name="sqlfile"><br>
<button type="submit">Upload & Import</button>
</form>
<?php mitacp_footer(); ?>
PHP

# phpmyadmin.php (link page)
cat > "$PANEL_DIR/phpmyadmin.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
echo '<h3>phpMyAdmin</h3><p><a href="/phpmyadmin/" target="_blank">Open phpMyAdmin</a></p>';
mitacp_footer();
?>
PHP

# filemanager.php (basic browse + view + save via helper)
cat > "$PANEL_DIR/filemanager.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
$base = '/var/www';
$path = isset($_GET['p'])? realpath($base.'/'.ltrim($_GET['p'],'/')) : $base;
if(strpos($path, $base)!==0) { die('Invalid path'); }
if(isset($_GET['edit'])){
  $file = $path.'/'.basename($_GET['edit']);
  if($_SERVER['REQUEST_METHOD']=='POST'){
    $content = $_POST['content'];
    $b64 = base64_encode($content);
    $cmd = "sudo $HELPER_DIR/file_write.sh " . escapeshellarg($file) . ' ' . escapeshellarg($b64);
    $out = shell_exec($cmd);
    echo '<div>'.htmlspecialchars($out).'</div>';
  }
  echo '<h3>Edit: '.htmlspecialchars($file).'</h3>';
  echo '<form method="post"><textarea name="content" style="width:100%;height:400px;">'.htmlspecialchars(file_get_contents($file)).'</textarea><br><button>Save</button></form>';
  exit;
}
$files = scandir($path);
echo '<h3>File Manager: '.htmlspecialchars($path).'</h3><ul>';
foreach($files as $f){ if($f=='.' || $f=='..') continue; echo '<li>'.htmlspecialchars($f).' - <a href="?p='.urlencode(str_replace($base.'/','',$path)).'&edit='.urlencode($f).'">edit</a></li>'; }
echo '</ul>';
mitacp_footer();
?>
PHP

# litespeed.php (tools + issue SSL form + restart/status/reload)
cat > "$PANEL_DIR/litespeed.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(isset($_GET['action']) && $_GET['action']=='restart'){
  shell_exec('/usr/local/lsws/bin/lswsctrl restart');
  echo '<div>OpenLiteSpeed restarted</div>';
}
if(isset($_GET['action']) && $_GET['action']=='reload'){
  shell_exec('/usr/local/lsws/bin/lswsctrl restart');
  echo '<div>OpenLiteSpeed reloaded</div>';
}
if(isset($_GET['action']) && $_GET['action']=='status'){
  $status = shell_exec('systemctl is-active openlitespeed');
  echo '<div>Status: '.htmlspecialchars($status).'</div>';
}
if($_SERVER['REQUEST_METHOD']=='POST' && isset($_POST['issue_domain'])){
  $d = trim($_POST['issue_domain']);
  $cmd = "sudo $HELPER_DIR/issue_ssl.sh " . escapeshellarg($d);
  $out = shell_exec($cmd);
  echo '<div>'.htmlspecialchars($out).'</div>';
}
?>
<a href="?action=restart">Restart OpenLiteSpeed</a> | <a href="?action=reload">Reload</a> | <a href="?action=status">Status</a>
<h3>Issue Free SSL (Let's Encrypt)</h3>
<form method="post">Domain: <input name="issue_domain"><button>Issue SSL</button></form>
<?php mitacp_footer(); ?>
PHP

# change_admin.php (English)
cat > "$PANEL_DIR/change_admin.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
$adminFile = __DIR__.'/admin.json';
$creds = json_decode(file_get_contents($adminFile), true);
if($_SERVER['REQUEST_METHOD']=='POST' && isset($_POST['new_user'])){
  $creds['user'] = trim($_POST['new_user']);
  $creds['pass'] = trim($_POST['new_pass']);
  file_put_contents($adminFile, json_encode($creds));
  echo '<div>Admin credentials updated</div>';
}
echo '<form method="post">User: <input name="new_user" value="'.htmlspecialchars($creds['user']).'"><br>Password: <input name="new_pass" value="'.htmlspecialchars($creds['pass']).'"><br><button>Save</button></form>';
mitacp_footer();
?>
PHP

# finalize permissions
chown -R nobody:nobody "$PANEL_DIR" 2>/dev/null || true
chmod -R 755 "$PANEL_DIR"

# 12.1) Setup standalone PHP server for mitacp on port 2083
PANEL_PORT=2083
PANEL_HOST="0.0.0.0"

cat > /etc/systemd/system/mitacp.service <<EOF
[Unit]
Description=MITACP mini panel on port $PANEL_PORT
After=network.target

[Service]
Type=simple
User=nobody
WorkingDirectory=$PANEL_DIR
ExecStart=/usr/local/lsws/lsphp74/bin/lsphp -S $PANEL_HOST:$PANEL_PORT -t $PANEL_DIR
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mitacp.service

# 13) Enable & start services
systemctl enable --now openlitespeed
systemctl enable --now mariadb

# 14) Final banner / instructions
cat <<EOF

==> MITACP installation finished successfully.

Access your new panel at: http://YOUR_SERVER_IP/mitacp/
Access your new panel at: http://YOUR_SERVER_IP:2083/

Default admin credentials: admin / admin123456
You can change admin credentials inside the panel (Change Admin Credentials).

phpMyAdmin: http://YOUR_SERVER_IP/phpmyadmin/
OpenLiteSpeed Admin GUI: http://YOUR_SERVER_IP:7080 (run: sudo /usr/local/lsws/admin/misc/admpass.sh to set admin password)

To create a site: use the panel -> Add Site. The helper creates /var/www/<domain>/public_html and a symlink into OpenLiteSpeed Example html.
To issue SSL: either check Auto issue SSL when creating the site (requires the domain A record to point to this server) OR use LiteSpeed Tools -> Issue Free SSL.

SECURITY NOTES:
- Panel runs as the webserver user and uses a limited set of helper scripts via sudoers. This is minimal for automation but has risks. Restrict access to the panel (firewall, IP allowlist) and change default passwords.
- After issuing SSL, configure the OpenLiteSpeed virtual host to use the generated cert files under /etc/ssl/mitacp/<domain>/

EOF

exit 0
