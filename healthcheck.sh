#!/bin/sh
# =============================================================================
# jdoo - Smart Healthcheck Script
# =============================================================================
# Reads container state from a file written by entrypoint.sh.
# Returns healthy (exit 0) during startup/upgrade to prevent orchestrators
# from killing the container. Only checks HTTP when Odoo is actually running.
#
# States:
#   STARTING         → exit 0 (entrypoint initializing)
#   INITIALIZING     → exit 0 (database initialization in progress)
#   UPGRADING        → exit 0 (module upgrade in progress)
#   RUNNING          → exit 0 (Odoo HTTP responding)
#   RUNNING_LOADING  → exit 0 (Odoo process alive, loading modules)
#   RUNNING_NO_PROCESS → exit 1 (Odoo process not found — crashed)
#   RUNNING_HTTP_FAIL  → exit 1 (Odoo process alive, HTTP not responding)
#   UPGRADE_FAILED   → exit 1 (module upgrade failed)
#   UNKNOWN          → exit 1 (state file missing or unrecognized)
#
# Usage (Dockerfile):
#   HEALTHCHECK CMD /usr/local/bin/healthcheck.sh
#
# Check output via:
#   docker inspect --format='{{json .State.Health.Log}}' <container> | jq -r '.[-1].Output'
# =============================================================================

STATE_FILE="/var/lib/odoo/.container-state"
ODOO_PORT="${ODOO_PORT:-8069}"

STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "")

case "$STATE" in
    STARTING|INITIALIZING|UPGRADING|UPGRADE_RETRY)
        echo "$STATE"
        exit 0
        ;;
    RUNNING)
        # Layer 1: Is the Odoo process alive?
        # Use /proc instead of pgrep (not available in slim images)
        ODOO_ALIVE=false
        for cmdline_file in /proc/[0-9]*/cmdline; do
            if grep -ql "odoo-bin" "$cmdline_file" 2>/dev/null; then
                ODOO_ALIVE=true
                break
            fi
        done
        if [ "$ODOO_ALIVE" = "false" ]; then
            echo "RUNNING_NO_PROCESS"
            exit 1
        fi

        # Layer 2: Is HTTP responding?
        if curl -f -s -o /dev/null --connect-timeout 5 "http://localhost:${ODOO_PORT}/web/login"; then
            echo "RUNNING"
            exit 0
        fi

        # Process alive but HTTP not ready — still loading modules
        echo "RUNNING_LOADING"
        exit 0
        ;;
    UPGRADE_FAILED)
        echo "UPGRADE_FAILED"
        exit 1
        ;;
    *)
        echo "UNKNOWN"
        exit 1
        ;;
esac
