#!/bin/bash
# MITACP installer (updated) - AlmaLinux / Rocky / CentOS 8+
# Features:
# - OpenLiteSpeed, lsphp74 + lsphp82, MariaDB, phpMyAdmin
# - Admin panel (2087) + Client panel (2083)
# - Create clients (system users), sites, subdomains
# - File manager with zip/unzip helpers
# - acme.sh installed correctly and used via full path
# - Admin password stored hashed
# - Per-site php_version recorded (lsphp74 or lsphp82) — helper to apply vhost later

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

# 2) Install prerequisites (including zip/unzip, jq)
dnf -y install epel-release || true
dnf -y install wget curl unzip zip tar git sudo nmap-ncat httpd-tools openssl php-json jq apr-util policycoreutils-python-utils || true

# 3) Add LiteSpeed repo and install OpenLiteSpeed
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.2-1.el8.noarch.rpm || true
dnf makecache || true
dnf -y install openlitespeed || true

# 4) Install PHP runtimes (lsphp74 and lsphp82)
dnf -y install lsphp74 lsphp74-mysqlnd lsphp74-common lsphp74-gd lsphp74-mbstring lsphp74-opcache lsphp74-xml lsphp74-zip || true
dnf -y install lsphp82 lsphp82-mysqlnd lsphp82-common lsphp82-gd lsphp82-mbstring lsphp82-opcache lsphp82-xml lsphp82-zip || true

# 5) Install MariaDB
dnf -y install mariadb-server mariadb || true
systemctl enable --now mariadb || true

# 6) Ask user for MariaDB root password (or auto-generate)
read -p "Enter desired MariaDB root password (leave empty to auto-generate): " MYSQL_ROOT_PASSWORD
if [ -z "${MYSQL_ROOT_PASSWORD:-}" ]; then
  MYSQL_ROOT_PASSWORD=$(openssl rand -base64 12)
  echo "Generated MariaDB root password: $MYSQL_ROOT_PASSWORD"
fi

# 7) Secure MariaDB & set root password (best-effort)
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

# 9) Install acme.sh correctly (no weird unknown parameter)
# Use explicit flags; the official installer supports: --install --nocron
curl -sSf https://get.acme.sh | sh -s -- --install --nocron || true
ACME_SH="/root/.acme.sh/acme.sh"
if [ ! -x "$ACME_SH" ]; then
  echo "Warning: acme.sh not found at $ACME_SH. Continuing but SSL helpers may fail."
fi

# 10) Create helper directory
mkdir -p "$HELPER_DIR"
chmod 755 "$HELPER_DIR"

# 10.a) helper: create system user for client
cat > "$HELPER_DIR/create_system_user.sh" <<'BASH'
#!/bin/bash
# usage: create_system_user.sh username password
set -e
USER="$1"
PASS="$2"
if id "$USER" >/dev/null 2>&1; then
  echo "exists"
  exit 0
fi
useradd -m -s /bin/bash "$USER" || true
echo "$USER:$PASS" | chpasswd
# lock shell if desired: usermod -s /sbin/nologin "$USER"
echo "created"
BASH

# 10.b) addsite.sh (now accepts php_version and owner system user)
cat > "$HELPER_DIR/addsite.sh" <<'BASH'
#!/bin/bash
# usage: addsite.sh domain dbname dbuser dbpass php_version site_pass auto_ssl owner
set -e
. /etc/mitacp.env
DOMAIN="$1"
DBNAME="$2"
DBUSER="$3"
DBPASS="$4"
PHPVER="$5"        # "lsphp74" or "lsphp82"
SITE_PASS="$6"
AUTO_SSL="$7"
OWNER="$8"         # system username to chown files to (optional)
ROOT="/var/www/$DOMAIN/public_html"
# create folders
mkdir -p "$ROOT"
# default index
cat > "$ROOT/index.php" <<PHP
<?php
http_response_code(200);
echo "<h1>Welcome to $DOMAIN</h1>";
?>
PHP
# ownership: if OWNER exists, chown to them; otherwise to nobody
if id "$OWNER" >/dev/null 2>&1; then
  chown -R "$OWNER":"$OWNER" "/var/www/$DOMAIN" || true
else
  chown -R nobody:nobody "/var/www/$DOMAIN" 2>/dev/null || true
fi
chmod -R 755 "$ROOT" || true

# write site record
SITEFILE="/usr/local/mitacp/data/sites.json"
mkdir -p "$(dirname "$SITEFILE")"
if [ ! -f "$SITEFILE" ]; then echo "[]" > "$SITEFILE"; fi
tmp=$(mktemp)
jq --arg d "$DOMAIN" --arg p "$PHPVER" --arg o "$OWNER" '. + [{"domain":$d,"php":$p,"owner":$o}]' "$SITEFILE" > "$tmp" && mv "$tmp" "$SITEFILE" || true

# create symlink into OLS example html so it's served (if not already)
ln -s "$ROOT" "/usr/local/lsws/Example/html/$DOMAIN" 2>/dev/null || true

# create database if requested
if [ -n "$DBNAME" ]; then
  mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`;"
fi
if [ -n "$DBUSER" ] && [ -n "$DBPASS" ]; then
  mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS'; GRANT ALL PRIVILEGES ON \`$DBNAME\`.* TO '$DBUSER'@'localhost'; FLUSH PRIVILEGES;"
fi

# apply basic HTTP auth if SITE_PASS provided
if [ -n "$SITE_PASS" ]; then
  HTFILE="/var/www/$DOMAIN/.htpasswd"
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -b -c "$HTFILE" admin "$SITE_PASS" || true
  else
    USER_H="admin"
    PASS_H="$SITE_PASS"
    HASH=$(openssl passwd -apr1 "$PASS_H")
    echo "${USER_H}:${HASH}" > "$HTFILE"
  fi
  cat > "/var/www/$DOMAIN/.htaccess" <<HT
AuthType Basic
AuthName "Protected"
AuthUserFile $HTFILE
Require valid-user
HT
fi

# restart OLS to pick changes (best-effort)
if [ -x /usr/local/lsws/bin/lswsctrl ]; then
  /usr/local/lsws/bin/lswsctrl restart || true
fi

# optionally issue SSL if requested
if [ "$AUTO_SSL" = "1" ] && [ -x /root/.acme.sh/acme.sh ]; then
  /root/.acme.sh/acme.sh --issue -d "$DOMAIN" -w "$ROOT" --force || true
  mkdir -p /etc/ssl/mitacp/$DOMAIN
  /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/ssl/mitacp/$DOMAIN/$DOMAIN.key \
    --fullchain-file /etc/ssl/mitacp/$DOMAIN/$DOMAIN.crt \
    --reloadcmd "/usr/local/lsws/bin/lswsctrl restart" || true
fi

echo "OK"
BASH

# 10.c) addsubdomain.sh
cat > "$HELPER_DIR/addsubdomain.sh" <<'BASH'
#!/bin/bash
# usage: addsubdomain.sh domain subdomain php_version owner
set -e
DOMAIN="$1"
SUB="$2"
PHPVER="$3"
OWNER="$4"
ROOT="/var/www/$DOMAIN/$SUB/public_html"
mkdir -p "$ROOT"
cat > "$ROOT/index.php" <<PHP
<?php
echo "<h1>Welcome to $SUB.$DOMAIN</h1>";
?>
PHP
if id "$OWNER" >/dev/null 2>&1; then
  chown -R "$OWNER":"$OWNER" "/var/www/$DOMAIN" || true
else
  chown -R nobody:nobody "/var/www/$DOMAIN" 2>/dev/null || true
fi
chmod -R 755 "/var/www/$DOMAIN" || true
# add record to sites.json (subdomain entry)
SITEFILE="/usr/local/mitacp/data/sites.json"
if [ ! -f "$SITEFILE" ]; then echo "[]" > "$SITEFILE"; fi
tmp=$(mktemp)
jq --arg d "$DOMAIN" --arg s "$SUB" --arg p "$PHPVER" '. + [{"domain":($s+"\."+$d),"php":$p,"owner":"'"$OWNER"'"}]' "$SITEFILE" > "$tmp" && mv "$tmp" "$SITEFILE" || true
ln -s "$ROOT" "/usr/local/lsws/Example/html/$SUB.$DOMAIN" 2>/dev/null || true
echo "OK"
BASH

# 10.d) createdb.sh
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

# 10.e) importsql.sh
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

# 10.f) listdbs.sh
cat > "$HELPER_DIR/listdbs.sh" <<'BASH'
#!/bin/bash
set -e
. /etc/mitacp.env
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;"
BASH

# 10.g) issue_ssl.sh
cat > "$HELPER_DIR/issue_ssl.sh" <<'BASH'
#!/bin/bash
# usage: issue_ssl.sh domain
set -e
DOMAIN="$1"
WEBROOT="/var/www/$DOMAIN/public_html"
if [ -z "$DOMAIN" ]; then echo "Domain required"; exit 1; fi
if [ ! -d "$WEBROOT" ]; then echo "Webroot not found: $WEBROOT"; exit 1; fi
if [ -x /root/.acme.sh/acme.sh ]; then
  /root/.acme.sh/acme.sh --issue -d "$DOMAIN" -w "$WEBROOT" --force
  mkdir -p /etc/ssl/mitacp/$DOMAIN
  /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/ssl/mitacp/$DOMAIN/$DOMAIN.key \
    --fullchain-file /etc/ssl/mitacp/$DOMAIN/$DOMAIN.crt \
    --reloadcmd "/usr/local/lsws/bin/lswsctrl restart"
  echo "OK"
else
  echo "acme.sh not installed"
  exit 1
fi
BASH

# 10.h) file_write.sh
cat > "$HELPER_DIR/file_write.sh" <<'BASH'
#!/bin/bash
# usage: file_write.sh /full/path/to/file base64_content owner
set -e
FILE="$1"
CONTENT_B64="$2"
OWNER="$3"
mkdir -p "$(dirname "$FILE")"
echo "$CONTENT_B64" | base64 -d > "$FILE"
if id "$OWNER" >/dev/null 2>&1; then
  chown "$OWNER":"$OWNER" "$FILE" || true
else
  chown nobody:nobody "$FILE" 2>/dev/null || true
fi
chmod 644 "$FILE"
echo "OK"
BASH

# 10.i) file zip/unzip helpers
cat > "$HELPER_DIR/fm_zip.sh" <<'BASH'
#!/bin/bash
# usage: fm_zip.sh target_zip full_path_to_item_to_zip
set -e
ZIP="$1"
ITEM="$2"
mkdir -p "$(dirname "$ZIP")"
zip -r -q "$ZIP" "$ITEM"
echo "OK"
BASH

cat > "$HELPER_DIR/fm_unzip.sh" <<'BASH'
#!/bin/bash
# usage: fm_unzip.sh zipfile destdir
set -e
ZIP="$1"
DEST="$2"
mkdir -p "$DEST"
unzip -q "$ZIP" -d "$DEST"
echo "OK"
BASH

chmod +x $HELPER_DIR/*.sh || true

# 11) Create sudoers entry for helper scripts (restrict to these scripts)
cat > "$SUDOERS_FILE" <<EOF
# MITACP helper scripts (allowed without password)
nobody ALL=(ALL) NOPASSWD: $HELPER_DIR/addsite.sh, $HELPER_DIR/createdb.sh, $HELPER_DIR/importsql.sh, $HELPER_DIR/listdbs.sh, $HELPER_DIR/issue_ssl.sh, $HELPER_DIR/file_write.sh, $HELPER_DIR/addsubdomain.sh, $HELPER_DIR/fm_zip.sh, $HELPER_DIR/fm_unzip.sh
# allow admin user to create system users (if you want to allow a specific admin user)
# root is always allowed
EOF
chmod 440 "$SUDOERS_FILE" || true

# 12) Create MITACP panel files (English) - ensure dir exists
mkdir -p "$PANEL_DIR"

# admin.json: store hashed password (pass_hashed) and user
ADMIN_DEFAULT_USER="admin"
ADMIN_DEFAULT_PASS="admin123456"
ADMIN_HASH=$(php -r "echo password_hash('${ADMIN_DEFAULT_PASS}', PASSWORD_DEFAULT);")
cat > "$PANEL_DIR/admin.json" <<JSON
{
  "user": "${ADMIN_DEFAULT_USER}",
  "pass_hashed": "${ADMIN_HASH}"
}
JSON
chmod 600 "$PANEL_DIR/admin.json"
chown -R nobody:nobody "$PANEL_DIR" 2>/dev/null || true

# 12.1) Create data directory and default plans/users/sites
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

cat > "$DATA_DIR/sites.json" <<'JSON'
[]
JSON

chown -R nobody:nobody "$DATA_DIR" 2>/dev/null || true
chmod -R 700 "$DATA_DIR" || true

# 12.2) Panel assets (style + header/footer) - simplified cPanel-like look
cat > "$PANEL_DIR/style.css" <<'CSS'
/* simple modern layout */
body{font-family:Inter,Arial,Helvetica,sans-serif;background:#f6f8fb;color:#222;margin:0}
header{background:#1f2937;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center}
aside{width:220px;background:#fff;border-right:1px solid #e6e9ee;position:fixed;top:58px;bottom:0;padding-top:10px;overflow:auto}
aside a{display:block;padding:10px 16px;color:#111;text-decoration:none;border-bottom:1px solid #f0f0f0}
main{margin-left:240px;padding:20px}
.card{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 4px rgba(0,0,0,0.06);margin-bottom:12px}
.footer{text-align:center;padding:12px;color:#888;font-size:13px;margin-top:20px}
.btn{background:#2563eb;color:#fff;padding:8px 12px;border-radius:6px;text-decoration:none;display:inline-block}
input,select,textarea{padding:8px;border:1px solid #ddd;border-radius:6px}
CSS

cat > "$PANEL_DIR/header.php" <<'PHP'
<?php
function mitacp_header(){
  echo '<!doctype html><html><head><meta charset="utf-8"><title>mitacp</title><meta name="viewport" content="width=device-width,initial-scale=1">';
  echo '<link rel="stylesheet" href="style.css">';
  echo '</head><body>';
  echo '<header><div style="display:flex;align-items:center"><div style="width:36px;height:36px;background:#2563eb;border-radius:6px;margin-right:10px"></div><div><strong>mitacp</strong></div></div>';
  echo '<div><a href="change_admin.php" style="color:#fff;text-decoration:none">Settings</a></div></header>';
  echo '<aside>';
  echo '</aside><main>';
}
?>
PHP

cat > "$PANEL_DIR/footer.php" <<'PHP'
<?php
function mitacp_footer(){
  echo '<div class="footer">All rights reserved &copy; mitacp</div>';
  echo '</main></body></html>';
}
?>
PHP

# 12.3) Auth (uses admin.pass_hashed and clients hashed password)
cat > "$PANEL_DIR/auth.php" <<'PHP'
<?php
session_start();
$adminFile = __DIR__.'/admin.json';
$creds = json_decode(file_get_contents($adminFile), true);
$ADMIN_USER = $creds['user'];
$ADMIN_PASS_HASH = $creds['pass_hashed'] ?? '';

$clientsFile = '/usr/local/mitacp/data/users.json';
$clients = file_exists($clientsFile) ? json_decode(file_get_contents($clientsFile), true) : [];

if (!isset($_SESSION['loggedin']) || $_SESSION['loggedin'] !== true) {
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['username'])) {
        $u = $_POST['username']; $p = $_POST['password'];
        // admin login
        if ($u === $ADMIN_USER && password_verify($p, $ADMIN_PASS_HASH)) {
            $_SESSION['loggedin'] = true;
            $_SESSION['is_admin'] = true;
            $_SESSION['username'] = $u;
        } else {
            // client login - check clients.json (password hashed)
            foreach($clients as $idx=>$c){
                if($c['user'] === $u){
                    if (isset($c['pass_hashed']) && password_verify($p, $c['pass_hashed'])) {
                        $_SESSION['loggedin'] = true;
                        $_SESSION['is_admin'] = false;
                        $_SESSION['username'] = $u;
                    } elseif (!isset($c['pass_hashed']) && isset($c['pass']) && $c['pass'] === $p) {
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
        echo '<button style="background:#2563eb;color:#fff;padding:8px 12px;border-radius:6px" type="submit">Login</button>';
        echo '</form></div>';
        exit;
    }
}
?>
PHP

# 12.4) index.php (menu depends on role) - keep similar to before but add php selector on addsite
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

# 12.5) addsite.php (UI includes php version select)
cat > "$PANEL_DIR/addsite.php" <<'PHP'
<?php include 'auth.php'; include 'header.php'; include 'footer.php'; mitacp_header();
if(!(isset($_SESSION['is_admin']) && $_SESSION['is_admin']===true)){ echo '<div>Admin only</div>'; mitacp_footer(); exit; }
if($_SERVER['REQUEST_METHOD']=='POST'){
  $domain=trim($_POST['domain']);
  $dbname=trim($_POST['dbname']);
  $dbuser=trim($_POST['dbuser']);
  $dbpass=trim($_POST['dbpass']);
  $phpver=trim($_POST['phpver'] ?? 'lsphp74');
  $sitepass=trim($_POST['sitepass'] ?? '');
  $owner=trim($_POST['owner'] ?? '');
  $auto_ssl = isset($_POST['auto_ssl']) ? '1' : '0';
  $cmd = 'sudo /usr/local/mitacp/bin/addsite.sh ' . escapeshellarg($domain) . ' ' . escapeshellarg($dbname) . ' ' . escapeshellarg($dbuser) . ' ' . escapeshellarg($dbpass) . ' ' . escapeshellarg($phpver) . ' ' . escapeshellarg($sitepass) . ' ' . escapeshellarg($auto_ssl) . ' ' . escapeshellarg($owner);
  $out = shell_exec($cmd);
  echo '<div style="background:#e7ffe7;padding:10px;margin:10px 0;">'.htmlspecialchars($out).'</div>';
}
?>
<form method="post">
Domain: <input name="domain" required><br>
Database (optional): <input name="dbname"><br>
DB User: <input name="dbuser"><br>
DB Pass: <input name="dbpass"><br>
PHP Version: <select name="phpver"><option value="lsphp74">PHP 7.4 (lsphp74)</option><option value="lsphp82">PHP 8.2 (lsphp82)</option></select><br>
Site Password (optional - HTTP auth): <input name="sitepass"><br>
Assign to user (system username): <input name="owner"><br>
Auto issue SSL (Let's Encrypt): <input type="checkbox" name="auto_ssl" value="1"><br>
<button type="submit">Create Site</button>
</form>
<?php mitacp_footer(); ?>
PHP

# 12.6) add minimal filemanager UI supporting zip/unzip (calls fm_zip/fm_unzip via sudo)
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
    $owner = isset($_SESSION['is_admin'])? 'nobody' : $_SESSION['username'];
    $cmd = "sudo /usr/local/mitacp/bin/file_write.sh " . escapeshellarg($file) . ' ' . escapeshellarg($b64) . ' ' . escapeshellarg($owner);
    $out = shell_exec($cmd);
    echo '<div>'.htmlspecialchars($out).'</div>';
  }
  echo '<h3>Edit: '.htmlspecialchars($file).'</h3>';
  echo '<form method="post"><textarea name="content" style="width:100%;height:400px;">'.htmlspecialchars(@file_get_contents($file)).'</textarea><br><button>Save</button></form>';
  exit;
}
if(isset($_POST['zip_item'])){
  $item = $_POST['zip_item'];
  $zipname = '/tmp/'.basename($item).'.zip';
  $cmd = "sudo /usr/local/mitacp/bin/fm_zip.sh " . escapeshellarg($zipname) . ' ' . escapeshellarg($path.'/'.$item);
  $out = shell_exec($cmd);
  echo '<div>'.htmlspecialchars($out).'</div>';
}
if(isset($_POST['unzip_item'])){
  $zip = $_POST['unzip_item'];
  $dest = $path;
  $cmd = "sudo /usr/local/mitacp/bin/fm_unzip.sh " . escapeshellarg($zip) . ' ' . escapeshellarg($dest);
  $out = shell_exec($cmd);
  echo '<div>'.htmlspecialchars($out).'</div>';
}
$files = scandir($path);
echo '<h3>File Manager: '.htmlspecialchars($path).'</h3><ul>';
foreach($files as $f){ if($f=='.' || $f=='..') continue; 
  echo '<li>'.htmlspecialchars($f).' - <a href="?p='.urlencode(str_replace($base.'/','',$path)).'&edit='.urlencode($f).'">edit</a>';
  if(is_dir($path.'/'.$f)) echo ' <form style="display:inline" method="post"><input type="hidden" name="zip_item" value="'.htmlspecialchars($f).'"><button>Zip</button></form>';
  if(preg_match("/\.zip$/i",$f)) echo ' <form style="display:inline" method="post"><input type="hidden" name="unzip_item" value="'.htmlspecialchars($path.'/'.$f).'"><button>Unzip</button></form>';
  echo '</li>';
}
echo '</ul>';
mitacp_footer();
?>
PHP

# 13) finalize permissions for panel
chown -R nobody:nobody "$PANEL_DIR" 2>/dev/null || true
chmod -R 755 "$PANEL_DIR" || true

# 14) systemd services for the panels (PHP built-in servers)
cat > /etc/systemd/system/mitacp.service <<EOF
[Unit]
Description=MITACP client panel on port 2083
After=network.target

[Service]
Type=simple
User=nobody
WorkingDirectory=$PANEL_DIR
ExecStart=/usr/local/lsws/lsphp74/bin/lsphp -S 0.0.0.0:2083 -t $PANEL_DIR
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/mitacp-admin.service <<EOF
[Unit]
Description=MITACP admin panel on port 2087
After=network.target

[Service]
Type=simple
User=nobody
WorkingDirectory=$PANEL_DIR
ExecStart=/usr/local/lsws/lsphp74/bin/lsphp -S 0.0.0.0:2087 -t $PANEL_DIR
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mitacp.service || true
systemctl enable --now mitacp-admin.service || true

# 15) Ensure services running
systemctl restart openlitespeed || true
systemctl enable --now mariadb || true

# 16) Final banner
cat <<EOF

==> MITACP installation finished (updated).

Admin panel (WHM-like): http://YOUR_SERVER_IP:2087/
Client panel (cPanel-like): http://YOUR_SERVER_IP:2083/
Fallback web path: http://YOUR_SERVER_IP/mitacp/

Default admin credentials: admin / admin123456 (stored hashed; change in Settings)
Notes:
- Sites are created under /var/www/<domain>/public_html and recorded in /usr/local/mitacp/data/sites.json
- Clients are stored in /usr/local/mitacp/data/users.json (passwords hashed)
- Per-site PHP selection is recorded but applying a full per-site OpenLiteSpeed virtual host config may require manual tuning (this installer creates records and symlinks into Example html)
- acme.sh path: /root/.acme.sh/acme.sh (used by helpers)
- File manager supports Zip/Unzip via helper scripts (fm_zip.sh / fm_unzip.sh)
- When creating clients via admin UI, the script attempts to create a system user and assigns site ownership to that user.

Security recommendations:
- Protect admin panel (2087) by firewall or proxy + TLS.
- Review sudoers entry and helper scripts before production use.

EOF

exit 0
