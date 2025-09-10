#!/bin/bash
# MITACP full installer for AlmaLinux (OpenLiteSpeed + PHP 7.4 + MariaDB + phpMyAdmin + Mini Panel)
# Added: admin panel on 2087, client panel on 2083, plans/users, client/admin separation, hosting plans management, usage pages, styling.
# Updated: fixed acme.sh install, openlitespeed service handling, PHP helper path usage.

set -euo pipefail
ROOT_WEBROOT="/usr/local/lsws/Example/html"
PANEL_DIR="$ROOT_WEBROOT/mitacp"
HELPER_DIR="/usr/local/mitacp/bin"
ENV_FILE="/etc/mitacp.env"
SUDOERS_FILE="/etc/sudoers.d/mitacp_helpers"
DATA_DIR="/usr/local/mitacp/data"

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

echo -e "\n==> MITACP installer starting..."

# 1) Update system
dnf -y update

# 2) Install prerequisites
dnf -y install epel-release
dnf -y install wget curl unzip tar git sudo nmap-ncat httpd-tools openssl php-json jq httpd-tools apr-util

# 3) Add LiteSpeed repo and install OpenLiteSpeed
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.2-1.el8.noarch.rpm || true
dnf makecache
dnf -y install openlitespeed || true

# 4) Install PHP 7.4 (lsphp74) and common modules
dnf -y install lsphp74 lsphp74-mysqlnd lsphp74-common lsphp74-gd lsphp74-mbstring lsphp74-opcache lsphp74-xml lsphp74-zip || true

# 5) Install MariaDB
dnf -y install mariadb-server mariadb || true
systemctl enable --now mariadb || true

# 6) Ask user for MariaDB root password (or auto-generate)
read -p "Enter desired MariaDB root password (leave empty to auto-generate): " MYSQL_ROOT_PASSWORD
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
  MYSQL_ROOT_PASSWORD=$(openssl rand -base64 12)
  echo "Generated MariaDB root password: $MYSQL_ROOT_PASSWORD"
fi

# 7) Secure MariaDB & set root password
systemctl restart mariadb || true
sleep 2
mysql --user=root <<SQL || true
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
SQL

# Save env file for helper scripts
mkdir -p /etc
cat > "$ENV_FILE" <<EOF
# MITACP environment
MYSQL_ROOT_PASSWORD='${MYSQL_ROOT_PASSWORD}'
EOF
chmod 600 "$ENV_FILE"

# 8) Install phpMyAdmin into webroot
mkdir -p "$ROOT_WEBROOT"
cd /tmp
PMA_URL="https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz"
wget -q "$PMA_URL" -O /tmp/phpmyadmin.tar.gz || true
tar xzf /tmp/phpmyadmin.tar.gz -C /tmp || true
PMA_DIR=$(ls -d /tmp/phpMyAdmin-*-all-languages 2>/dev/null | head -n1 || true)
if [ -d "$PMA_DIR" ]; then
  rm -rf "$ROOT_WEBROOT/phpmyadmin" || true
  mv "$PMA_DIR" "$ROOT_WEBROOT/phpmyadmin" || true
  chown -R nobody:nobody "$ROOT_WEBROOT/phpmyadmin" || true
fi
rm -f /tmp/phpmyadmin.tar.gz

# 9) Install acme.sh for Let's Encrypt (will be used by issue_ssl helper)
# Use correct install flags to avoid the "Unknown parameter" error.
curl -s https://get.acme.sh | sh -s -- --install --nocron || true
ACME_SH="/root/.acme.sh/acme.sh"

# 10) Create helper scripts
mkdir -p "$HELPER_DIR"

# addsite.sh (supports HTTP auth and owner)
cat > "$HELPER_DIR/addsite.sh" <<'BASH'
#!/bin/bash
# usage: addsite.sh domain dbname dbuser dbpass site_pass auto_ssl owner
set -e
. /etc/mitacp.env
DOMAIN="$1"
DBNAME="$2"
DBUSER="$3"
DBPASS="$4"
SITE_PASS="$5"
AUTO_SSL="$6"
OWNER="$7"
ROOT="/var/www/$DOMAIN/public_html"
# create folders
mkdir -p "$ROOT"
chown -R nobody:nobody "$ROOT" 2>/dev/null || chown -R "$(whoami):$(whoami)" "$ROOT" 2>/dev/null || true
chmod -R 755 "$ROOT"
# default index
cat > "$ROOT/index.php" <<PHP
<?php
http_response_code(200);
echo "<h1>Welcome to $DOMAIN</h1>";
?>
PHP
# apply basic HTTP auth if SITE_PASS provided
if [ -n "$SITE_PASS" ]; then
  HTFILE="/var/www/$DOMAIN/.htpasswd"
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -b -c "$HTFILE" admin "$SITE_PASS" || true
  else
    USER="admin"
    PASS="$SITE_PASS"
    HASH=$(openssl passwd -apr1 "$PASS")
    echo "${USER}:${HASH}" > "$HTFILE"
  fi
  cat > "/var/www/$DOMAIN/.htaccess" <<HT
AuthType Basic
AuthName "Protected"
AuthUserFile $HTFILE
Require valid-user
HT
fi

# symlink into OLS example html so it's served
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

# if OWNER provided, assign site to user in data file (simple)
if [ -n "$OWNER" ]; then
  DATAFILE="/usr/local/mitacp/data/users.json"
  if [ -f "$DATAFILE" ]; then
    # add site field for owner if exists
    tmp=$(mktemp)
    jq --arg u "$OWNER" --arg d "$DOMAIN" 'map(if .user==$u then .site=$d else . end)' "$DATAFILE" > "$tmp" && mv "$tmp" "$DATAFILE" || true
  fi
fi

echo "OK"
BASH

# createdb.sh
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

# importsql.sh
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

# listdbs.sh
cat > "$HELPER_DIR/listdbs.sh" <<'BASH'
#!/bin/bash
set -e
. /etc/mitacp.env
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;"
BASH

# issue_ssl.sh
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

# file_write.sh
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

chmod +x $HELPER_DIR/*.sh || true

# 11) Create sudoers entry for nobody to run helper scripts (restricted)
cat > "$SUDOERS_FILE" <<EOF
# MITACP helper scripts (allowed without password)
nobody ALL=(ALL) NOPASSWD: $HELPER_DIR/addsite.sh, $HELPER_DIR/createdb.sh, $HELPER_DIR/importsql.sh, $HELPER_DIR/listdbs.sh, $HELPER_DIR/issue_ssl.sh, $HELPER_DIR/file_write.sh
EOF
chmod 440 "$SUDOERS_FILE" || true

# 12) Create MITACP panel files (English)
mkdir -p "$PANEL_DIR"

# admin.json default credentials (admin can login to admin panel 2087)
cat > "$PANEL_DIR/admin.json" <<'EOF'
{
  "user": "admin",
  "pass": "admin123456"
}
EOF
chmod 600 "$PANEL_DIR/admin.json"
chown -R nobody:nobody "$PANEL_DIR" 2>/dev/null || true

# 12.1) Create data directory and default plans/users
mkdir -p "$DATA_DIR"
cat > "$DATA_DIR/plans.json" <<'JSON'
[
  {"name":"Basic","sites":1,"dbs":1,"disk_mb":1024,"bandwidth_gb":50},
  {"name":"Pro","sites":5,"dbs":10,"disk_mb":10240,"bandwidth_gb":200},
  {"name":"Unlimited","sites":999,"dbs":999,"disk_mb":-1,"bandwidth_gb":-1}
]
JSON

cat > "$DATA_DIR/users.json" <<'JSON'
[]
JSON

chown -R nobody:nobody "$DATA_DIR" 2>/dev/null || true
chmod -R 700 "$DATA_DIR" || true

# 12.2) Create panel assets: style.css and small logo
cat > "$PANEL_DIR/style.css" <<'CSS'
body { margin:0; font-family: Arial, Helvetica, sans-serif; background:#f4f7fb; color:#222; }
header{ background:#243763; color:#fff; padding:12px 18px; display:flex; justify-content:space-between; align-items:center; }
header h1{ margin:0; font-size:18px; }
aside{ width:220px; background:#fff; border-right:1px solid #e6e9ee; position:fixed; top:58px; bottom:0; padding-top:10px; overflow:auto; }
aside a{ display:block; padding:10px 16px; color:#333; text-decoration:none; border-bottom:1px solid #f0f0f0; }
aside a:hover{ background:#f6f8fb; }
main{ margin-left:240px; padding:20px; }
.card{ background:#fff; border-radius:8px; padding:16px; box-shadow:0 1px 4px rgba(0,0,0,0.06); margin-bottom:12px; }
.footer{ text-align:center; padding:12px; color:#888; font-size:13px; margin-top:20px; }
.btn{ background:#2b6cb0; color:#fff; padding:8px 12px; border-radius:6px; text-decoration:none; }
small.gray{ color:#777; }
CSS

# header.php
cat > "$PANEL_DIR/header.php" <<'PHP'
<?php
function mitacp_header(){
  echo '<!doctype html><html><head><meta charset="utf-8"><title>mitacp</title>';
  echo '<link rel="stylesheet" href="style.css">';
  echo '</head><body>';
  echo '<header><div style="display:flex;align-items:center"><img src="data:image/svg+xml;utf8,<svg xmlns=%22http://www.w3.org/2000/svg%22 width=%2224%22 height=%2224%22><rect width=%2224%22 height=%2224%22 rx=%224%22 fill=%22%23243663%22/></svg>" alt="logo" style="margin-right:8px;">';
  echo '<h1>mitacp</h1></div>';
  echo '<div><a href="change_admin.php" style="color:#fff;text-decoration:none">Settings</a></div></header>';
  echo '<aside>';
  // menu will be shown in index.php based on role
  echo '</aside><main>';
}
?>
PHP

# footer.php
cat > "$PANEL_DIR/footer.php" <<'PHP'
<?php
function mitacp_footer(){
  echo '<div class="footer">All rights reserved &copy; mitacp - mitatag.com</div>';
  echo '</main></body></html>';
}
?>
PHP

# auth.php (supports admin (admin.json) and clients (data/users.json); clients passwords hashed)
# Note: PHP files use hardcoded helper path '/usr/local/mitacp/bin' when calling shell helpers.
cat > "$PANEL_DIR/auth.php" <<'PHP'
<?php
session_start();
$adminFile = __DIR__.'/admin.json';
$creds = json_decode(file_get_contents($adminFile), true);
$ADMIN_USER = $creds['user'];
$ADMIN_PASS = $creds['pass'];

// load clients
$clientsFile = '/usr/local/mitacp/data/users.json';
$clients = file_exists($clientsFile) ? json_decode(file_get_contents($clientsFile), true) : [];

if (!isset($_SESSION['loggedin']) || $_SESSION['loggedin'] !== true) {
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['username'])) {
        $u = $_POST['username']; $p = $_POST['password'];
        // admin login
        if ($u === $ADMIN_USER && $p === $ADMIN_PASS) {
            $_SESSION['loggedin'] = true;
            $_SESSION['is_admin'] = true;
            $_SESSION['username'] = $u;
        } else {
            // client login - check clients.json (password hashed)
            foreach($clients as $idx=>$c){
                if($c['user']===$u){
                    if (isset($c['pass_hashed']) && password_verify($p, $c['pass_hashed'])) {
                        $_SESSION['loggedin'] = true;
                        $_SESSION['is_admin'] = false;
                        $_SESSION['username'] = $u;
                    } elseif (!isset($c['pass_hashed']) && isset($c['pass']) && $c['pass']===$p) {
                        // legacy plain password - accept and re-hash
                        $_SESSION['loggedin'] = true;
                        $_SESSION['is_admin'] = false;
                        $_SESSION['username'] = $u;
                        $clients[$idx]['pass_hashed'] = password_hash($p, PASSWORD_DEFAULT);
                        file_put_contents($clientsFile, json_encode($clients, JSON_PRETTY_PRINT));
                    }
                    break;
                }
            }
            if(!isset($_SESSION['username'])) echo '<div style="color:red;">Invalid credentials</div>';
        }
    }
    if (!isset($_SESSION['loggedin']) || $_SESSION['loggedin'] !== true) {
        echo '<div style="padding:20px;max-width:420px;margin:40px auto;background:#fff;border-radius:8px;box-shadow:0 2px 6px rgba(0,0,0,0.08)">';
        echo '<h3>Login to mitacp</h3>';
        echo '<form method="post">';
        echo 'Username: <input name="username" style="width:100%;padding:8px;margin:6px 0"><br>';
        echo 'Password: <input type="password" name="password" style="width:100%;padding:8px;margin:6px 0"><br>';
        echo '<button style="background:#2b6cb0;color:#fff;padding:8px 12px;border-radius:6px" type="submit">Login</button>';
        echo '</form></div>';
        exit;
    }
}
?>
PHP

# index.php (shows admin/client menu)
cat > "$PANEL_DIR/index.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header(); ?>
<?php
echo '<aside>';
if(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true){
  echo '<a href="index.php">Dashboard</a>';
  echo '<a href="addsite.php">Add Site</a>';
  echo '<a href="adddb.php">Add Database</a>';
  echo '<a href="sites.php">Manage Sites</a>';
  echo '<a href="dbs.php">Manage Databases</a>';
  echo '<a href="uploadsql.php">Import SQL</a>';
  echo '<a href="filemanager.php">File Manager</a>';
  echo '<a href="litespeed.php">LiteSpeed Tools</a>';
  echo '<a href="phpmyadmin.php">phpMyAdmin</a>';
  echo '<a href="plans.php">Hosting Plans</a>';
  echo '<a href="clients.php">Clients</a>';
  echo '<a href="server_load.php">Server Load</a>';
  echo '<a href="change_admin.php">Change Admin Credentials</a>';
} else {
  echo '<a href="index.php">Dashboard</a>';
  echo '<a href="filemanager.php">File Manager</a>';
  echo '<a href="phpmyadmin.php">phpMyAdmin</a>';
  echo '<a href="myplan.php">My Plan</a>';
  echo '<a href="usage.php">Usage</a>';
  echo '<a href="change_admin.php">Change Password</a>';
}
echo '</aside>';
?>
<main>
  <div class="card">
    <h2>Welcome to MITACP</h2>
    <p class="gray">Quick access:</p>
    <?php if(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true): ?>
      <p>Admin panel available on port <strong>2087</strong>. Client panel on <strong>2083</strong>.</p>
    <?php else: ?>
      <p>Client panel available on port <strong>2083</strong>.</p>
    <?php endif; ?>
  </div>
</main>
<?php mitacp_footer(); ?>
PHP

# addsite.php (updated to accept site password and owner)
cat > "$PANEL_DIR/addsite.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
if($_SERVER['REQUEST_METHOD']=='POST'){
  $domain=trim($_POST['domain']);
  $dbname=trim($_POST['dbname']);
  $dbuser=trim($_POST['dbuser']);
  $dbpass=trim($_POST['dbpass']);
  $sitepass=trim($_POST['sitepass'] ?? '');
  $owner=trim($_POST['owner'] ?? '');
  $auto_ssl = isset($_POST['auto_ssl']) ? '1' : '0';
  $cmd = 'sudo /usr/local/mitacp/bin/addsite.sh ' . escapeshellarg($domain) . ' ' . escapeshellarg($dbname) . ' ' . escapeshellarg($dbuser) . ' ' . escapeshellarg($dbpass) . ' ' . escapeshellarg($sitepass) . ' ' . escapeshellarg($auto_ssl) . ' ' . escapeshellarg($owner);
  $out = shell_exec($cmd);
  echo '<div style="background:#e7ffe7;padding:10px;margin:10px 0;">'.htmlspecialchars($out).'</div>';
}
?>
<form method="post">
Domain: <input name="domain" required><br>
Database (optional): <input name="dbname"><br>
DB User: <input name="dbuser"><br>
DB Pass: <input name="dbpass"><br>
Site Password (optional - HTTP auth): <input name="sitepass"><br>
Assign to user (optional username): <input name="owner"><br>
Auto issue SSL (Let's Encrypt): <input type="checkbox" name="auto_ssl" value="1"><br>
<button type="submit">Create Site</button>
</form>
<?php mitacp_footer(); ?>
PHP

# adddb.php
cat > "$PANEL_DIR/adddb.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
if($_SERVER['REQUEST_METHOD']=='POST'){
  $dbname=$_POST['dbname']; $dbuser=$_POST['dbuser']; $dbpass=$_POST['dbpass'];
  $cmd = 'sudo /usr/local/mitacp/bin/createdb.sh ' . escapeshellarg($dbname) . ' ' . escapeshellarg($dbuser) . ' ' . escapeshellarg($dbpass);
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
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
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
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
$out = shell_exec('sudo /usr/local/mitacp/bin/listdbs.sh');
echo '<pre>'.htmlspecialchars($out).'</pre>';
mitacp_footer();
?>
PHP

# uploadsql.php
cat > "$PANEL_DIR/uploadsql.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
if($_SERVER['REQUEST_METHOD']=='POST' && isset($_FILES['sqlfile'])){
  $dbname = $_POST['dbname'];
  $tmp = $_FILES['sqlfile']['tmp_name'];
  $target = '/tmp/'.basename($_FILES['sqlfile']['name']);
  move_uploaded_file($tmp, $target);
  $cmd = 'sudo /usr/local/mitacp/bin/importsql.sh ' . escapeshellarg($dbname) . ' ' . escapeshellarg($target);
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

# filemanager.php (basic)
cat > "$PANEL_DIR/filemanager.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
// determine allowed base for user
$base = '/var/www';
if(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===false){
  // client: limit to their site
  $users = json_decode(file_get_contents('/usr/local/mitacp/data/users.json'), true);
  $uname = $_SESSION['username'];
  $site = '';
  foreach($users as $u){ if($u['user']===$uname){ $site = $u['site'] ?? ''; break; } }
  if($site===''){ echo '<div>No site assigned.</div>'; mitacp_footer(); exit; }
  $base = '/var/www/'.$site.'/public_html';
}
$path = isset($_GET['p'])? realpath($base.'/'.ltrim($_GET['p'],'/')) : realpath($base);
if($path === false || strpos($path, $base)!==0) { die('Invalid path'); }
if(isset($_GET['edit'])){
  $file = $path.'/'.basename($_GET['edit']);
  if($_SERVER['REQUEST_METHOD']=='POST'){
    $content = $_POST['content'];
    $b64 = base64_encode($content);
    $cmd = 'sudo /usr/local/mitacp/bin/file_write.sh ' . escapeshellarg($file) . ' ' . escapeshellarg($b64);
    $out = shell_exec($cmd);
    echo '<div>'.htmlspecialchars($out).'</div>';
  }
  echo '<h3>Edit: '.htmlspecialchars($file).'</h3>';
  echo '<form method="post"><textarea name="content" style="width:100%;height:400px;">'.htmlspecialchars(@file_get_contents($file)).'</textarea><br><button>Save</button></form>';
  exit;
}
$files = scandir($path);
echo '<h3>File Manager: '.htmlspecialchars($path).'</h3><ul>';
foreach($files as $f){ if($f=='.' || $f=='..') continue; echo '<li>'.htmlspecialchars($f).' - <a href="?p='.urlencode(str_replace($base.'/','',$path)).'&edit='.urlencode($f).'">edit</a></li>'; }
echo '</ul>';
mitacp_footer();
?>
PHP

# litespeed.php (tools + issue SSL)
cat > "$PANEL_DIR/litespeed.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
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
  $cmd = 'sudo /usr/local/mitacp/bin/issue_ssl.sh ' . escapeshellarg($d);
  $out = shell_exec($cmd);
  echo '<div>'.htmlspecialchars($out).'</div>';
}
?>
<a href="?action=restart">Restart OpenLiteSpeed</a> | <a href="?action=reload">Reload</a> | <a href="?action=status">Status</a>
<h3>Issue Free SSL (Let's Encrypt)</h3>
<form method="post">Domain: <input name="issue_domain"><button>Issue SSL</button></form>
<?php mitacp_footer(); ?>
PHP

# change_admin.php (admin can change admin credentials; clients can change their password)
cat > "$PANEL_DIR/change_admin.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
$adminFile = __DIR__.'/admin.json';
$creds = json_decode(file_get_contents($adminFile), true);
if(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true){
  if($_SERVER['REQUEST_METHOD']=='POST' && isset($_POST['new_user'])){
    $creds['user'] = trim($_POST['new_user']);
    $creds['pass'] = trim($_POST['new_pass']);
    file_put_contents($adminFile, json_encode($creds, JSON_PRETTY_PRINT));
    echo '<div>Admin credentials updated</div>';
  }
  echo '<form method="post">User: <input name="new_user" value="'.htmlspecialchars($creds['user']).'"><br>Password: <input name="new_pass" value="'.htmlspecialchars($creds['pass']).'"><br><button>Save</button></form>';
} else {
  // client can change their own password
  $dataU = '/usr/local/mitacp/data/users.json';
  $users = json_decode(file_get_contents($dataU), true);
  $uname = $_SESSION['username'];
  if($_SERVER['REQUEST_METHOD']=='POST' && isset($_POST['new_pass'])){
    $new = $_POST['new_pass'];
    foreach($users as &$u){ if($u['user']===$uname){ $u['pass_hashed'] = password_hash($new, PASSWORD_DEFAULT); break; } }
    file_put_contents($dataU, json_encode($users, JSON_PRETTY_PRINT));
    echo '<div>Password updated</div>';
  }
  echo '<form method="post">New password: <input name="new_pass"><br><button>Change</button></form>';
}
mitacp_footer();
?>
PHP

# plans.php (admin)
cat > "$PANEL_DIR/plans.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
$dataFile = '/usr/local/mitacp/data/plans.json';
$plans = json_decode(file_get_contents($dataFile), true);
if($_SERVER['REQUEST_METHOD']=='POST' && isset($_POST['action'])){
  if($_POST['action']=='add'){
    $plans[] = ['name'=>$_POST['name'],'sites'=>intval($_POST['sites']),'dbs'=>intval($_POST['dbs']),'disk_mb'=>intval($_POST['disk_mb']),'bandwidth_gb'=>intval($_POST['bandwidth_gb'])];
    file_put_contents($dataFile, json_encode($plans, JSON_PRETTY_PRINT));
    echo '<div>Plan added</div>';
  } elseif($_POST['action']=='delete'){
    $idx = intval($_POST['idx']);
    array_splice($plans,$idx,1);
    file_put_contents($dataFile, json_encode($plans, JSON_PRETTY_PRINT));
    echo '<div>Plan deleted</div>';
  }
  $plans = json_decode(file_get_contents($dataFile), true);
}
?>
<h3>Hosting Plans</h3>
<ul>
<?php foreach($plans as $i=>$p){ echo '<li>'.htmlspecialchars($p['name']).' - Sites: '.$p['sites'].' DBs: '.$p['dbs'].' Disk: '.($p['disk_mb']>0?$p['disk_mb'].'MB':'Unlimited').' <form style="display:inline" method="post"><input type="hidden" name="idx" value="'.$i.'"><button name="action" value="delete">Delete</button></form></li>'; } ?>
</ul>
<h4>Add Plan</h4>
<form method="post">
Name: <input name="name" required><br>
Sites: <input name="sites" value="1"><br>
DBs: <input name="dbs" value="1"><br>
Disk (MB, -1 for unlimited): <input name="disk_mb" value="1024"><br>
Bandwidth (GB, -1 unlimited): <input name="bandwidth_gb" value="50"><br>
<button name="action" value="add">Add Plan</button>
</form>
<?php mitacp_footer(); ?>
PHP

# clients.php and create_client.php (admin)
cat > "$PANEL_DIR/clients.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
$dataU = '/usr/local/mitacp/data/users.json';
$dataP = '/usr/local/mitacp/data/plans.json';
$users = json_decode(file_get_contents($dataU), true);
$plans = json_decode(file_get_contents($dataP), true);
if($_SERVER['REQUEST_METHOD']=='POST' && isset($_POST['action'])){
  if($_POST['action']=='delete'){
    $u = $_POST['user'];
    foreach($users as $k=>$v){ if($v['user']==$u){ array_splice($users,$k,1); break; } }
    file_put_contents($dataU, json_encode($users, JSON_PRETTY_PRINT));
    echo '<div>Deleted</div>';
  } elseif($_POST['action']=='assign'){
    $u = $_POST['user']; $plan = $_POST['plan'];
    foreach($users as &$c){ if($c['user']==$u){ $c['plan']=$plan; break; } }
    file_put_contents($dataU, json_encode($users, JSON_PRETTY_PRINT));
    echo '<div>Assigned</div>';
  }
  $users = json_decode(file_get_contents($dataU), true);
}
?>
<h3>Clients</h3>
<table border="1" cellpadding="6">
<tr><th>User</th><th>Site</th><th>Plan</th><th>Actions</th></tr>
<?php foreach($users as $u){ echo '<tr><td>'.htmlspecialchars($u['user']).'</td><td>'.htmlspecialchars($u['site']??'').'</td><td>'.htmlspecialchars($u['plan']??'').'</td><td>
<form style="display:inline" method="post"><input type="hidden" name="user" value="'.htmlspecialchars($u['user']).'"><select name="plan">'.array_reduce($plans,function($carry,$p){return $carry.'<option value="'.htmlspecialchars($p['name']).'">'.htmlspecialchars($p['name']).'</option>';},'').'</select><button name="action" value="assign">Assign</button></form>
<form style="display:inline" method="post"><input type="hidden" name="user" value="'.htmlspecialchars($u['user']).'"><button name="action" value="delete">Delete</button></form>
</td></tr>'; } ?>
</table>
<p><a href="create_client.php">Create new client</a></p>
<?php mitacp_footer(); ?>
PHP

cat > "$PANEL_DIR/create_client.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
$dataU = '/usr/local/mitacp/data/users.json';
$plans = json_decode(file_get_contents('/usr/local/mitacp/data/plans.json'), true);
$users = json_decode(file_get_contents($dataU), true);
if($_SERVER['REQUEST_METHOD']=='POST'){
  $user = trim($_POST['user']); $pass = trim($_POST['pass']); $site = trim($_POST['site']); $plan=trim($_POST['plan']);
  $users[] = ['user'=>$user,'pass'=>'','pass_hashed'=>password_hash($pass, PASSWORD_DEFAULT),'site'=>$site,'db'=>'','plan'=>$plan];
  file_put_contents($dataU, json_encode($users, JSON_PRETTY_PRINT));
  echo '<div>Client created</div>';
}
?>
<h3>Create Client</h3>
<form method="post">
Username: <input name="user" required><br>
Password: <input name="pass" required><br>
Site (domain): <input name="site"><br>
Plan: <select name="plan"><?php foreach($plans as $p) echo '<option value="'.htmlspecialchars($p['name']).'">'.htmlspecialchars($p['name']).'</option>'; ?></select><br>
<button>Create</button>
</form>
<?php mitacp_footer(); ?>
PHP

# server_load.php (admin)
cat > "$PANEL_DIR/server_load.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
echo '<h3>Server Load & Stats</h3>';
echo '<div class="card"><h4>CPU & Processes</h4><pre>'.shell_exec("top -bn1 | head -n5").'</pre></div>';
echo '<div class="card"><h4>Memory</h4><pre>'.shell_exec("free -m").'</pre></div>';
echo '<div class="card"><h4>Disk</h4><pre>'.shell_exec("df -h").'</pre></div>';
echo '<div class="card"><h4>Processes count</h4><pre>'.shell_exec("ps aux | wc -l").'</pre></div>';
mitacp_footer();
?>
PHP

# myplan.php (client)
cat > "$PANEL_DIR/myplan.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!isset($_SESSION['username'])){ echo '<div>Please login</div>'; mitacp_footer(); exit; }
$dataU = '/usr/local/mitacp/data/users.json';
$users = json_decode(file_get_contents($dataU), true);
$current = null;
foreach($users as $u){ if($u['user']===$_SESSION['username']){ $current=$u; break; } }
if($current===null){ echo '<div>No client record</div>'; mitacp_footer(); exit; }
$plans = json_decode(file_get_contents('/usr/local/mitacp/data/plans.json'), true);
$planDetails = null;
foreach($plans as $p){ if($p['name']==($current['plan']??'')){ $planDetails=$p; break; } }
echo '<h3>My Plan</h3>';
if($planDetails){
  echo '<ul>';
  echo '<li>Name: '.htmlspecialchars($planDetails['name']).'</li>';
  echo '<li>Sites: '.htmlspecialchars($planDetails['sites']).'</li>';
  echo '<li>DBs: '.htmlspecialchars($planDetails['dbs']).'</li>';
  echo '<li>Disk: '.($planDetails['disk_mb']>0?$planDetails['disk_mb'].' MB':'Unlimited').'</li>';
  echo '<li>Bandwidth: '.($planDetails['bandwidth_gb']>0?$planDetails['bandwidth_gb'].' GB':'Unlimited').'</li>';
  echo '</ul>';
} else { echo '<div>No plan assigned.</div>'; }
mitacp_footer();
?>
PHP

# usage.php (client)
cat > "$PANEL_DIR/usage.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!isset($_SESSION['username'])){ echo '<div>Please login</div>'; mitacp_footer(); exit; }
$dataU = '/usr/local/mitacp/data/users.json';
$users = json_decode(file_get_contents($dataU), true);
$current = null;
foreach($users as $u){ if($u['user']===$_SESSION['username']){ $current=$u; break; } }
if($current===null){ echo '<div>No client record</div>'; mitacp_footer(); exit; }
$site = $current['site'] ?? '';
$root = "/var/www/{$site}/public_html";
$diskUsed = 'N/A';
if(is_dir($root)){
  $du = trim(shell_exec("du -sm ".escapeshellarg($root)." 2>/dev/null | cut -f1"));
  $diskUsed = $du . " MB";
}
echo "<h3>Usage for site ".htmlspecialchars($site)."</h3>";
echo "<p>Disk used: ".htmlspecialchars($diskUsed)."</p>";
echo "<p>Assigned DB: ".htmlspecialchars($current['db'] ?? 'None')."</p>";
mitacp_footer();
?>
PHP

# finalize permissions
chown -R nobody:nobody "$PANEL_DIR" 2>/dev/null || true
chmod -R 755 "$PANEL_DIR" || true

# 13) Setup standalone PHP server for mitacp on port 2083 (client)
PANEL_PORT=2083
PANEL_HOST="0.0.0.0"

cat > /etc/systemd/system/mitacp.service <<EOF
[Unit]
Description=MITACP client panel on port $PANEL_PORT
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

# 14) Setup admin PHP server for mitacp on port 2087
PANEL_PORT_ADMIN=2087
cat > /etc/systemd/system/mitacp-admin.service <<EOF
[Unit]
Description=MITACP Admin panel on port $PANEL_PORT_ADMIN
After=network.target

[Service]
Type=simple
User=nobody
WorkingDirectory=$PANEL_DIR
ExecStart=/usr/local/lsws/lsphp74/bin/lsphp -S 0.0.0.0:$PANEL_PORT_ADMIN -t $PANEL_DIR
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mitacp.service || true
systemctl enable --now mitacp-admin.service || true

# 15) Enable & start services (handle OpenLiteSpeed restart safely)
systemctl restart openlitespeed || true
systemctl enable --now mariadb || true

# 16) Final banner / instructions
cat <<EOF

==> MITACP installation finished successfully.

Admin panel (WHM-like): http://YOUR_SERVER_IP:2087/
Client panel (cPanel-like): http://YOUR_SERVER_IP:2083/
Fallback web path: http://YOUR_SERVER_IP/mitacp/

Default admin credentials: admin / admin123456
(Please login to admin and create clients, assign plans, create sites)

phpMyAdmin: http://YOUR_SERVER_IP/phpmyadmin/
OpenLiteSpeed Admin GUI: http://YOUR_SERVER_IP:7080 (run: sudo /usr/local/lsws/admin/misc/admpass.sh to set admin password)

To create a site: Admin -> Add Site (can assign to client and set site password).
To issue SSL: either check Auto issue SSL when creating the site (requires domain A record) OR use LiteSpeed Tools -> Issue Free SSL.

SECURITY NOTES:
- Client passwords are stored hashed when created via the Admin UI.
- Panel runs on plain HTTP on ports 2083/2087 by default. Strongly recommend adding TLS/proxy or firewall rules before production usage.
- Restrict admin panel (2087) via firewall or IP allowlist.
- Review sudoers entry and helper scripts for additional hardening.

EOF

exit 0
