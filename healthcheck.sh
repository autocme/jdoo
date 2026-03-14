#!/bin/sh
# =============================================================================
# jdoo - Smart Healthcheck Script
# =============================================================================
# Reads container state from a file written by entrypoint.sh.
# Returns healthy (exit 0) ONLY when Odoo HTTP is actually responding.
# Docker's start_period protects the container from being killed during init.
#
# States:
#   STARTING         → exit 1 (entrypoint initializing — not ready)
#   INITIALIZING     → exit 1 (database initialization in progress — not ready)
#   UPGRADING        → exit 1 (module upgrade in progress — not ready)
#   RUNNING          → exit 0 if HTTP responds, exit 1 if still loading
#   RUNNING_NO_PROCESS → exit 1 (Odoo process not found — crashed)
#   UPGRADE_FAILED   → exit 1 (module upgrade failed)
#   UNKNOWN          → exit 1 (state file missing or unrecognized)
#
# The start_period in docker-compose.yml (default 600s) ensures Docker
# won't count these failures or restart the container during init.
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
        exit 1
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
        exit 1
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
