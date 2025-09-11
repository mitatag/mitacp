<?php
require_once "db.php";

// تحقق من تسجيل الدخول (جلسة)
session_start();
if (!isset($_SESSION['admin_logged']) || $_SESSION['admin_logged'] !== true) {
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && $_POST['username'] === $ADMIN_USER && password_verify($_POST['password'], $ADMIN_PASS)) {
        $_SESSION['admin_logged'] = true;
    } else {
        echo '<form method="POST">
                <input type="text" name="username" placeholder="Admin User" required>
                <input type="password" name="password" placeholder="Password" required>
                <button type="submit">Login</button>
              </form>';
        exit;
    }
}
?>
<h1>MITACP Dashboard</h1>
<ul>
    <li><a href="phpmyadmin/">phpMyAdmin</a></li>
    <li><a href="files/tinyfilemanager.php">مدير الملفات</a></li>
    <li><a href="domin.php">إدارة الدومينات</a></li>
</ul>
