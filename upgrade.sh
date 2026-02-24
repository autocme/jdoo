#!/bin/bash
# =============================================================================
# jdoo - Standalone Module Upgrade Script
# =============================================================================
# Runs click-odoo-update on Odoo databases sequentially (one at a time).
# Designed to be called externally by JCICD or other orchestrators.
#
# Flow:
#   1. Pause Odoo (SIGSTOP) to prevent DB conflicts
#   2. Discover databases
#   3. Upgrade each database sequentially (one by one)
#   4. Report per-database result
#   5. On success: resume Odoo (SIGCONT) — caller should restart for new code
#      On failure: resume Odoo (SIGCONT) with old code still loaded
#
# Usage:
#   docker exec <container> /usr/local/bin/upgrade.sh              # all DBs
#   docker exec <container> /usr/local/bin/upgrade.sh -d mydb      # one DB
#   docker exec <container> /usr/local/bin/upgrade.sh --check      # dry-run
#
# Exit codes:
#   0 = all databases upgraded successfully (or up-to-date)
#   1 = one or more databases failed
#
# After success, restart the container to load updated module code:
#   docker restart <container>
# =============================================================================

set -uo pipefail

ERP_CONF_PATH="${ERP_CONF_PATH:-/etc/odoo/erp.conf}"
ODOO_DATA_DIR="${ODOO_DATA_DIR:-/var/lib/odoo}"
STATE_FILE="${ODOO_DATA_DIR}/.container-state"
UPGRADE_LOG_DIR="${ODOO_DATA_DIR}/logs"

mkdir -p "$UPGRADE_LOG_DIR"

# Keep only last 5 upgrade runs, delete older ones
UPGRADE_KEEP=${UPGRADE_KEEP:-5}
for old_dir in $(ls -dt "${UPGRADE_LOG_DIR}"/upgrade-run-* 2>/dev/null | tail -n +$((UPGRADE_KEEP))); do
    rm -rf "$old_dir"
done

# Create a timestamped directory for this run
RUN_DIR="${UPGRADE_LOG_DIR}/upgrade-run-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$RUN_DIR"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log_info()  { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

# -----------------------------------------------------------------------------
# State management
# -----------------------------------------------------------------------------
PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "RUNNING")
ODOO_PIDS=""

set_state() {
    echo "$1" > "$STATE_FILE" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Find all odoo-bin PIDs (using /proc — pgrep not available in slim images)
# -----------------------------------------------------------------------------
find_odoo_pids() {
    ODOO_PIDS=""
    for cmdline_file in /proc/[0-9]*/cmdline; do
        if grep -ql "odoo-bin" "$cmdline_file" 2>/dev/null; then
            local pid
            pid=$(echo "$cmdline_file" | grep -o '[0-9]*')
            ODOO_PIDS="$ODOO_PIDS $pid"
        fi
    done
    ODOO_PIDS=$(echo "$ODOO_PIDS" | xargs)
}

# -----------------------------------------------------------------------------
# Pause Odoo (SIGSTOP — freezes processes without killing them)
# Safe for PID 1: container stays alive, DB connections held idle
# -----------------------------------------------------------------------------
pause_odoo() {
    find_odoo_pids

    if [ -z "$ODOO_PIDS" ]; then
        log_info "No Odoo process found (already stopped)."
        return 0
    fi

    log_info "Pausing Odoo processes: ${ODOO_PIDS}"
    for pid in $ODOO_PIDS; do
        kill -STOP "$pid" 2>/dev/null || true
    done
    log_info "Odoo paused."
}

# -----------------------------------------------------------------------------
# Resume Odoo (SIGCONT — unfreezes paused processes)
# -----------------------------------------------------------------------------
resume_odoo() {
    if [ -z "$ODOO_PIDS" ]; then
        return 0
    fi

    log_info "Resuming Odoo processes: ${ODOO_PIDS}"
    for pid in $ODOO_PIDS; do
        kill -CONT "$pid" 2>/dev/null || true
    done
    log_info "Odoo resumed."
}

# -----------------------------------------------------------------------------
# Cleanup: always resume Odoo and restore state on unexpected exit
# -----------------------------------------------------------------------------
cleanup() {
    resume_odoo
    set_state "$PREV_STATE"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
TARGET_DB="${ODOO_DB_NAME:-}"
CHECK_ONLY=false

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--database)
            TARGET_DB="$2"
            shift 2
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        -h|--help)
            echo "Usage: upgrade.sh [-d DATABASE] [--check]"
            echo "  -d, --database DB   Upgrade specific database (default: all)"
            echo "  --check             Dry-run: list what needs upgrading, don't execute"
            exit 0
            ;;
        *)
            log_warn "Unknown argument: $1"
            shift
            ;;
    esac
done

# =============================================================================
# Step 1: Pause Odoo
# =============================================================================
set_state "UPGRADING"
pause_odoo

# =============================================================================
# Step 2: Discover databases
# =============================================================================
DB_LIST="$TARGET_DB"

if [ -z "$DB_LIST" ]; then
    DB_HOST=$(printenv 'conf.db_host' 2>/dev/null || echo 'db')
    DB_PORT=$(printenv 'conf.db_port' 2>/dev/null || echo '5432')
    DB_USER=$(printenv 'conf.db_user' 2>/dev/null || echo 'odoo')
    DB_PASS=$(printenv 'conf.db_password' 2>/dev/null || echo 'odoo')

    DB_LIST=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -t -c \
        "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres', 'template0', 'template1') ORDER BY datname;" \
        2>/dev/null | xargs)

    if [ -z "$DB_LIST" ]; then
        log_info "No databases found."
        trap - EXIT
        resume_odoo
        set_state "$PREV_STATE"
        exit 0
    fi
fi

DB_COUNT=$(echo "$DB_LIST" | wc -w)
log_info "Databases to process: ${DB_COUNT} (${DB_LIST})"

UPDATE_FLAGS=""
IGNORE_CORE="${UPGRADE_IGNORE_CORE:-TRUE}"
IGNORE_CORE="${IGNORE_CORE^^}"
if [ "$IGNORE_CORE" = "TRUE" ]; then
    UPDATE_FLAGS="--ignore-core-addons"
    log_info "Ignoring core addons (UPGRADE_IGNORE_CORE=TRUE)"
fi

# =============================================================================
# Step 3: Upgrade each database sequentially (one by one)
# =============================================================================
TOTAL=0
SUCCEEDED=0
FAILED=0
SKIPPED=0
FAILED_DBS=""
FAILED_REASONS=""

for DB_NAME in $DB_LIST; do
    TOTAL=$((TOTAL + 1))
    DB_LOG="${RUN_DIR}/${DB_NAME}.log"
    log_info "=== [${TOTAL}/${DB_COUNT}] ${DB_NAME} ==="

    # Check what needs upgrading (--logfile captures click-odoo-update output)
    CHECK_LOG="/tmp/upgrade-check-${DB_NAME}.log"
    rm -f "$CHECK_LOG"
    if ! gosu odoo click-odoo-update -c "$ERP_CONF_PATH" -d "$DB_NAME" --if-exists $UPDATE_FLAGS --list-only --logfile "$CHECK_LOG" 2>&1; then
        log_error "[FAIL] ${DB_NAME}: could not check for updates."
        [ -f "$CHECK_LOG" ] && cp "$CHECK_LOG" "$DB_LOG"
        FAILED=$((FAILED + 1))
        FAILED_DBS="$FAILED_DBS $DB_NAME"
        FAILED_REASONS="${FAILED_REASONS}${DB_NAME}: could not check for updates\n"
        if [ -f "$DB_LOG" ]; then
            log_error "--- Last 10 lines from ${DB_NAME} ---"
            tail -10 "$DB_LOG" >&2
            log_error "--- Full log: ${DB_LOG} ---"
        fi
        rm -f "$CHECK_LOG"
        continue
    fi

    # Show check output for visibility
    if grep -q "Updating addons for their hash changed\|to update" "$CHECK_LOG" 2>/dev/null; then
        log_info "[CHECK] ${DB_NAME}: modules to update:"
        grep -E "to update|hash changed|Updating" "$CHECK_LOG" 2>/dev/null | while IFS= read -r line; do
            log_info "  $line"
        done
    else
        log_info "[SKIP] ${DB_NAME}: up-to-date."
        SKIPPED=$((SKIPPED + 1))
        rm -f "$CHECK_LOG"
        continue
    fi

    rm -f "$CHECK_LOG"

    if [ "$CHECK_ONLY" = true ]; then
        log_info "[CHECK] ${DB_NAME}: upgrades available."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    log_info "Upgrading ${DB_NAME}..."

    # Run upgrade with --logfile to capture full output
    if gosu odoo click-odoo-update -c "$ERP_CONF_PATH" -d "$DB_NAME" --if-exists $UPDATE_FLAGS --i18n-overwrite --logfile "$DB_LOG" 2>&1; then
        log_info "[OK] ${DB_NAME}: upgraded successfully."
        SUCCEEDED=$((SUCCEEDED + 1))
        # Show key lines from upgrade log
        if [ -f "$DB_LOG" ]; then
            grep -E "Updating addons|modules loaded|Registry loaded|error|Error|FAIL" "$DB_LOG" 2>/dev/null | while IFS= read -r line; do
                log_info "  $line"
            done
        fi
    else
        local_exit=${PIPESTATUS[0]}
        log_error "[FAIL] ${DB_NAME}: upgrade failed (exit code ${local_exit})."
        FAILED=$((FAILED + 1))
        FAILED_DBS="$FAILED_DBS $DB_NAME"
        FAILED_REASONS="${FAILED_REASONS}${DB_NAME}: exit code ${local_exit}\n"
        log_error "--- Last 20 lines from ${DB_NAME} ---"
        tail -20 "$DB_LOG" >&2
        log_error "--- Full log: ${DB_LOG} ---"
    fi
done

# =============================================================================
# Step 4: Report results and write result file
# =============================================================================
log_info "=========================================="
log_info "Upgrade Summary: ${DB_COUNT} database(s)"
log_info "  Succeeded: ${SUCCEEDED}"
log_info "  Skipped:   ${SKIPPED} (up-to-date)"
log_info "  Failed:    ${FAILED}"
if [ -n "$FAILED_DBS" ]; then
    log_info "  Failed DBs:${FAILED_DBS}"
fi
log_info "=========================================="

# Write machine-readable result file
if [ "$FAILED" -gt 0 ]; then
    RESULT_STATUS="FAILED"
else
    RESULT_STATUS="OK"
fi

cat > "${RUN_DIR}/result" <<EOF
STATUS=${RESULT_STATUS}
TOTAL=${DB_COUNT}
SUCCEEDED=${SUCCEEDED}
SKIPPED=${SKIPPED}
FAILED=${FAILED}
FAILED_DBS=${FAILED_DBS}
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
EOF

# Symlink latest result for easy access
ln -sfn "$RUN_DIR" "${UPGRADE_LOG_DIR}/latest"

# =============================================================================
# Step 5: Resume Odoo and set final state
# =============================================================================
trap - EXIT

if [ "$FAILED" -gt 0 ]; then
    set_state "UPGRADE_FAILED"
    resume_odoo
    log_error "Upgrade completed with failures. Odoo resumed with old code."
    log_error "Result: ${RUN_DIR}/result"
    log_error "Logs:   ${RUN_DIR}/"
    exit 1
fi

resume_odoo
set_state "$PREV_STATE"

if [ "$SUCCEEDED" -gt 0 ]; then
    log_info "All upgrades succeeded. Restart the container to load new code:"
    log_info "  docker restart <container>"
fi

exit 0