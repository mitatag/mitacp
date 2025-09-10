#!/bin/bash
# MITACP setup on port 2089
# Set SERVER_ROOT
SERVER_ROOT="/usr/local/lsws"

# Paths
VHOST_NAME="MITACP_VHOST"
VHOST_ROOT="$SERVER_ROOT/Example/html/mitacp"
VHOST_CONF_DIR="$SERVER_ROOT/conf/vhosts/$VHOST_NAME"
VHOST_CONF_FILE="$VHOST_CONF_DIR/vhconf.conf"
HTTPD_CONF="$SERVER_ROOT/conf/httpd_config.xml"

# Create required directories
mkdir -p "$VHOST_CONF_DIR"
mkdir -p "$VHOST_ROOT"
mkdir -p "$VHOST_CONF_DIR/logs"

# Create vhconf.conf
cat > "$VHOST_CONF_FILE" <<EOL
virtualhost $VHOST_NAME {
    vhRoot
