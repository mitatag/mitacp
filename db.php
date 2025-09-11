<?php
define("DB_HOST", "localhost");
define("DB_NAME", "mitacp");
define("DB_USER", "root");
define("DB_PASS", "ادخل_كلمة_مرور_الـDB_هنا");

$ADMIN_USER = 'ادخل_ادمن_هنا';
$ADMIN_PASS = password_hash('ادخل_باسورد_ادمن_هنا', PASSWORD_DEFAULT);

$conn = new mysqli(DB_HOST, DB_USER, DB_PASS, DB_NAME);
if ($conn->connect_error) {
    die("Connection failed: " . $conn->connect_error);
}
?>
