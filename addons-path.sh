#!/bin/sh
# =============================================================================
# jdoo - Addons Path Query Script
# =============================================================================
# Reads the configured addons_path from erp.conf and outputs each path
# on its own line. Designed for JCICD and other orchestrators.
#
# Usage:
#   docker exec <container> /usr/local/bin/addons-path.sh
#
# Output (one path per line):
#   /opt/odoo/addons
#   /opt/odoo/odoo/addons
#   /mnt/extra-addons
#   /repos/19.0/oc-addons
# =============================================================================

ERP_CONF_PATH="${ERP_CONF_PATH:-/etc/odoo/erp.conf}"

if [ ! -f "$ERP_CONF_PATH" ]; then
    echo "ERROR: Config file not found: $ERP_CONF_PATH" >&2
    exit 1
fi

ADDONS_PATH=$(grep "^addons_path" "$ERP_CONF_PATH" 2>/dev/null | sed 's/^addons_path *= *//')

if [ -z "$ADDONS_PATH" ]; then
    echo "ERROR: addons_path not found in $ERP_CONF_PATH" >&2
    exit 1
fi

echo "$ADDONS_PATH" | tr ',' '\n' | sed 's/^ *//;s/ *$//'
