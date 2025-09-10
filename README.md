# mitacp
mitacp panel vps litespeed

# MITACP
Mini Hosting Control Panel (AlmaLinux + OpenLiteSpeed + MariaDB + PHP 7.4)

## Features
- Add sites (with DB + SSL optional)
- Manage databases
- Import SQL
- File manager (basic edit/save)
- LiteSpeed tools (restart / reload / status)
- phpMyAdmin integration
- Free SSL (Let's Encrypt via acme.sh)

## Installation
```bash
wget https://raw.githubusercontent.com/mitatag/mitacp/main/install.sh -O install.sh
chmod +x install.sh
sudo ./install.sh
