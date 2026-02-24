#!/bin/bash
# =============================================================================
# jdoo - Universal Odoo Entrypoint (Supports Odoo 15.0 - 19.0+)
# =============================================================================
# Handles: PUID/PGID, resource auto-compute, config generation,
#          version-specific mappings, package installs, DB init,
#          auto-upgrade, report.url fix, and Odoo startup
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration Variables
# -----------------------------------------------------------------------------
ERP_CONF_PATH="${ERP_CONF_PATH:-/etc/odoo/erp.conf}"
ODOO_DATA_DIR="${ODOO_DATA_DIR:-/var/lib/odoo}"
ODOO_SOURCE="${ODOO_SOURCE:-/opt/odoo}"
ODOO_VERSION="${ODOO_VERSION:-19.0}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Extract major version number (15, 16, 17, 18, 19...)
ODOO_MAJOR=$(echo "${ODOO_VERSION}" | cut -d. -f1)

# State file for healthcheck (read by healthcheck.sh)
STATE_FILE="${ODOO_DATA_DIR}/.container-state"

# Write container state (visible via docker inspect healthcheck output)
set_state() {
    echo "$1" > "$STATE_FILE" 2>/dev/null || true
    log_info "Container state: $1"
}

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

# -----------------------------------------------------------------------------
# Step 1: Handle PUID/PGID - Adjust odoo user/group to match requested IDs
# -----------------------------------------------------------------------------
setup_user_permissions() {
    log_info "Setting up user permissions (PUID=${PUID}, PGID=${PGID})..."

    CURRENT_UID=$(id -u odoo 2>/dev/null || echo "")
    CURRENT_GID=$(getent group odoo | cut -d: -f3 2>/dev/null || echo "")

    if [ -n "$CURRENT_GID" ] && [ "$CURRENT_GID" != "$PGID" ]; then
        log_info "Changing odoo group GID from ${CURRENT_GID} to ${PGID}..."
        groupmod -o -g "$PGID" odoo
    fi

    if [ -n "$CURRENT_UID" ] && [ "$CURRENT_UID" != "$PUID" ]; then
        log_info "Changing odoo user UID from ${CURRENT_UID} to ${PUID}..."
        usermod -o -u "$PUID" odoo
    fi

    log_info "Fixing ownership of Odoo directories..."
    chown -R odoo:odoo "$ODOO_DATA_DIR" || true
    chown -R odoo:odoo /etc/odoo || true
    chown -R odoo:odoo /mnt/extra-addons 2>/dev/null || true

    log_info "User permissions configured successfully."
}

# -----------------------------------------------------------------------------
# Step 2: Auto-compute resource allocation from container CPU/RAM
# Detects cgroup v1/v2 limits, calculates workers and memory limits
# All values overridable via WORKERS, MAX_CRON_THREADS, LIMIT_MEMORY_* env vars
# -----------------------------------------------------------------------------

# Parse cpuset strings like "0-3" or "0,2,4" or "0-1,4-5" into a CPU count
parse_cpuset() {
    local cpuset="$1"
    local count=0
    IFS=',' read -ra ranges <<< "$cpuset"
    for range in "${ranges[@]}"; do
        if [[ "$range" == *-* ]]; then
            local start="${range%-*}"
            local end="${range#*-}"
            count=$(( count + end - start + 1 ))
        else
            count=$(( count + 1 ))
        fi
    done
    echo "$count"
}

# Detect available CPUs (respects Docker --cpus and --cpuset-cpus limits)
get_cpu_count() {
    # Method 1: cgroup v2 cpu.max (Docker --cpus limit)
    if [ -f /sys/fs/cgroup/cpu.max ]; then
        local max period
        read -r max period < /sys/fs/cgroup/cpu.max 2>/dev/null || true
        if [ "${max:-max}" != "max" ] && [ "${period:-0}" -gt 0 ] 2>/dev/null; then
            local cpus=$(( (max + period - 1) / period ))
            if [ "$cpus" -gt 0 ] 2>/dev/null; then
                echo "$cpus"
                return
            fi
        fi
    fi

    # Method 2: cgroup v2 cpuset.cpus.effective (Docker --cpuset-cpus)
    if [ -f /sys/fs/cgroup/cpuset.cpus.effective ]; then
        local cpuset
        cpuset=$(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null)
        if [ -n "$cpuset" ]; then
            local cpus
            cpus=$(parse_cpuset "$cpuset")
            if [ "$cpus" -gt 0 ] 2>/dev/null; then
                echo "$cpus"
                return
            fi
        fi
    fi

    # Method 3: cgroup v1 cpu quota
    if [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        local quota period
        quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)
        period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
        if [ "${quota:-0}" -gt 0 ] && [ "${period:-0}" -gt 0 ] 2>/dev/null; then
            local cpus=$(( (quota + period - 1) / period ))
            if [ "$cpus" -gt 0 ] 2>/dev/null; then
                echo "$cpus"
                return
            fi
        fi
    fi

    # Method 4: cgroup v1 cpuset
    if [ -f /sys/fs/cgroup/cpuset/cpuset.cpus ]; then
        local cpuset
        cpuset=$(cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null)
        if [ -n "$cpuset" ]; then
            local cpus
            cpus=$(parse_cpuset "$cpuset")
            if [ "$cpus" -gt 0 ] 2>/dev/null; then
                echo "$cpus"
                return
            fi
        fi
    fi

    # Method 5: /proc/cpuinfo fallback (all host CPUs)
    local cpus
    cpus=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo 1)
    echo "${cpus:-1}"
}

# Detect available RAM in bytes (respects Docker --memory limit)
get_ram_bytes() {
    # Method 1: cgroup v2 memory.max
    if [ -f /sys/fs/cgroup/memory.max ]; then
        local mem_max
        mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        if [ "${mem_max:-max}" != "max" ] && [ "$mem_max" -gt 0 ] 2>/dev/null; then
            echo "$mem_max"
            return
        fi
    fi

    # Method 2: cgroup v1 memory limit
    if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        local mem_limit
        mem_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        # cgroup v1 uses ~9.2 EB when unlimited — treat as no limit
        if [ "${mem_limit:-0}" -gt 0 ] && [ "$mem_limit" -lt 9223372036854771712 ] 2>/dev/null; then
            echo "$mem_limit"
            return
        fi
    fi

    # Method 3: /proc/meminfo fallback (all host RAM)
    local mem_kb
    mem_kb=$(grep "^MemTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}')
    if [ -n "$mem_kb" ] && [ "$mem_kb" -gt 0 ] 2>/dev/null; then
        echo $(( mem_kb * 1024 ))
        return
    fi

    # Fallback: 2GB
    echo 2147483648
}

compute_resources() {
    log_info "Computing resource allocation..."

    local cpu_count ram_bytes
    cpu_count=$(get_cpu_count)
    ram_bytes=$(get_ram_bytes)

    local ram_mb=$(( ram_bytes / 1024 / 1024 ))
    local ram_gb=$(( ram_mb / 1024 ))
    log_info "  Detected: ${cpu_count} CPU(s), ${ram_mb}MB RAM (~${ram_gb}GB)"

    # --- Workers ---
    # Odoo formula: (CPU * 2) + 1 total processes
    # We use CPU * 2 for HTTP workers (the +1 is the cron)
    local workers
    if [ -n "$(printenv 'conf.workers' 2>/dev/null)" ]; then
        log_info "  Workers: $(printenv 'conf.workers') (from conf.workers, skipping auto-compute)"
        log_info "Resource allocation complete (manual conf.* mode)."
        COMPUTED_WORKERS=""
        return 0
    fi

    if [ -n "${WORKERS:-}" ]; then
        workers="$WORKERS"
        log_info "  Workers: ${workers} (from WORKERS env var)"
    else
        workers=$(( cpu_count * 2 ))
        [ "$workers" -lt 2 ] && workers=2
        log_info "  Workers: ${workers} (auto: CPU*2)"
    fi

    # --- Cron Threads ---
    local max_cron_threads
    if [ -n "${MAX_CRON_THREADS:-}" ]; then
        max_cron_threads="$MAX_CRON_THREADS"
        log_info "  Cron threads: ${max_cron_threads} (from MAX_CRON_THREADS env var)"
    else
        if [ "$workers" -ge 6 ]; then
            max_cron_threads=2
        else
            max_cron_threads=1
        fi
        log_info "  Cron threads: ${max_cron_threads} (auto)"
    fi

    # --- Memory Limits (per worker) ---
    # Odoo's limit_memory_soft/hard are PER WORKER limits
    # Formula: allocate 85% of RAM across all processes
    # Soft = per-worker allocation, Hard = soft * 1.3
    local total_procs=$(( workers + max_cron_threads ))

    local limit_memory_soft
    if [ -n "${LIMIT_MEMORY_SOFT:-}" ]; then
        limit_memory_soft="$LIMIT_MEMORY_SOFT"
        local soft_mb=$(( limit_memory_soft / 1024 / 1024 ))
        log_info "  Memory soft: ${soft_mb}MB (from LIMIT_MEMORY_SOFT env var)"
    else
        # 85% of RAM / total processes (divide first to avoid overflow)
        limit_memory_soft=$(( (ram_bytes / 100 * 85) / total_procs ))

        # Cap between 128MB and 2.5GB per worker
        local min_soft=134217728    # 128MB
        local max_soft=2684354560   # 2.5GB
        [ "$limit_memory_soft" -lt "$min_soft" ] && limit_memory_soft=$min_soft
        [ "$limit_memory_soft" -gt "$max_soft" ] && limit_memory_soft=$max_soft

        local soft_mb=$(( limit_memory_soft / 1024 / 1024 ))
        log_info "  Memory soft: ${soft_mb}MB/worker (auto: 85% RAM / ${total_procs} procs)"
    fi

    local limit_memory_hard
    if [ -n "${LIMIT_MEMORY_HARD:-}" ]; then
        limit_memory_hard="$LIMIT_MEMORY_HARD"
        local hard_mb=$(( limit_memory_hard / 1024 / 1024 ))
        log_info "  Memory hard: ${hard_mb}MB (from LIMIT_MEMORY_HARD env var)"
    else
        limit_memory_hard=$(( limit_memory_soft * 13 / 10 ))
        local hard_mb=$(( limit_memory_hard / 1024 / 1024 ))
        log_info "  Memory hard: ${hard_mb}MB/worker (auto: soft*1.3)"
    fi

    # --- Save computed values (applied after generate_config) ---
    # bash can't export vars with dots, so we save to regular vars
    # and apply_resources() writes them to erp.conf
    COMPUTED_WORKERS="${workers}"
    COMPUTED_MAX_CRON_THREADS="${max_cron_threads}"
    COMPUTED_LIMIT_MEMORY_SOFT="${limit_memory_soft}"
    COMPUTED_LIMIT_MEMORY_HARD="${limit_memory_hard}"

    # Summary
    local total_ram_needed=$(( (soft_mb * total_procs) ))
    log_info "  Total estimated RAM: ~${total_ram_needed}MB for ${total_procs} processes"
    log_info "Resource allocation complete."
}

# Write computed resource values to erp.conf (runs after generate_config)
apply_resources() {
    if [ -z "${COMPUTED_WORKERS:-}" ]; then
        return 0  # conf.* mode or nothing to apply
    fi

    log_info "Applying computed resources to ${ERP_CONF_PATH}..."

    # Append resource settings (only if not already in config from conf.* env vars)
    if ! grep -q "^workers" "$ERP_CONF_PATH" 2>/dev/null; then
        echo "workers = ${COMPUTED_WORKERS}" >> "$ERP_CONF_PATH"
        log_info "  Config: workers = ${COMPUTED_WORKERS}"
    fi
    if ! grep -q "^max_cron_threads" "$ERP_CONF_PATH" 2>/dev/null; then
        echo "max_cron_threads = ${COMPUTED_MAX_CRON_THREADS}" >> "$ERP_CONF_PATH"
        log_info "  Config: max_cron_threads = ${COMPUTED_MAX_CRON_THREADS}"
    fi
    if ! grep -q "^limit_memory_soft" "$ERP_CONF_PATH" 2>/dev/null; then
        echo "limit_memory_soft = ${COMPUTED_LIMIT_MEMORY_SOFT}" >> "$ERP_CONF_PATH"
        log_info "  Config: limit_memory_soft = ${COMPUTED_LIMIT_MEMORY_SOFT}"
    fi
    if ! grep -q "^limit_memory_hard" "$ERP_CONF_PATH" 2>/dev/null; then
        echo "limit_memory_hard = ${COMPUTED_LIMIT_MEMORY_HARD}" >> "$ERP_CONF_PATH"
        log_info "  Config: limit_memory_hard = ${COMPUTED_LIMIT_MEMORY_HARD}"
    fi
}

# -----------------------------------------------------------------------------
# Step 3: Generate Odoo Configuration from conf.* Environment Variables
# Includes version-specific parameter mapping (e.g., longpolling_port)
# -----------------------------------------------------------------------------
generate_config() {
    log_info "Generating Odoo configuration at ${ERP_CONF_PATH}..."

    mkdir -p "$(dirname "$ERP_CONF_PATH")"

    echo "[options]" > "$ERP_CONF_PATH"

    while IFS='=' read -r name value; do
        if [[ "$name" == conf.* ]]; then
            key="${name#conf.}"
            echo "${key} = ${value}" >> "$ERP_CONF_PATH"
            log_info "  Config: ${key} = ${value}"
        fi
    done < <(env)

    # -------------------------------------------------------------------------
    # Dynamic addons_path: include /mnt/synced-addons only if it has addons
    # -------------------------------------------------------------------------
    if [ -d /mnt/synced-addons ] && [ "$(ls -A /mnt/synced-addons 2>/dev/null)" ]; then
        if grep -q "^addons_path" "$ERP_CONF_PATH"; then
            # Append synced-addons paths if not already present
            if ! grep -q "synced-addons" "$ERP_CONF_PATH"; then
                sed -i "s|^addons_path = \(.*\)|addons_path = \1,/mnt/synced-addons,/mnt/synced-addons/oc-addons|" "$ERP_CONF_PATH"
                log_info "  Added /mnt/synced-addons to addons_path (content detected)"
            fi
        fi
    else
        log_info "  /mnt/synced-addons is empty, skipping"
    fi

    # -------------------------------------------------------------------------
    # Version-specific config mappings
    # -------------------------------------------------------------------------
    # Odoo 17+ renamed longpolling_port to gevent_port
    if [ "$ODOO_MAJOR" -ge 17 ]; then
        if grep -q "^longpolling_port" "$ERP_CONF_PATH"; then
            sed -i 's/^longpolling_port/gevent_port/' "$ERP_CONF_PATH"
            log_info "  Mapped: longpolling_port -> gevent_port (Odoo ${ODOO_VERSION})"
        fi
    fi

    chown odoo:odoo "$ERP_CONF_PATH"
    chmod 640 "$ERP_CONF_PATH"

    log_info "Configuration file generated successfully."
}

# -----------------------------------------------------------------------------
# Step 4: Python Package Installation (PY_INSTALL)
# Stateless - checks if packages are installed at each startup
# -----------------------------------------------------------------------------
install_python_packages() {
    local py_install="${PY_INSTALL:-}"

    if [ -z "$py_install" ]; then
        log_info "PY_INSTALL not set, skipping Python package installation."
        return 0
    fi

    log_info "Checking Python packages: ${py_install}..."

    local needs_install=false
    IFS=',' read -ra PKG_ARRAY <<< "$py_install"

    for pkg in "${PKG_ARRAY[@]}"; do
        pkg=$(echo "$pkg" | xargs)  # Trim whitespace

        if [ -z "$pkg" ]; then
            continue
        fi

        if [[ "$pkg" == *"=="* ]]; then
            local pkg_name="${pkg%%==*}"
            local pkg_version="${pkg#*==}"

            if pip show "$pkg_name" 2>/dev/null | grep -q "Version: $pkg_version"; then
                log_info "  [ok] $pkg already installed"
            else
                log_info "  [need] $pkg needs installation/upgrade"
                needs_install=true
            fi
        else
            if pip show "$pkg" &>/dev/null; then
                local installed_version
                installed_version=$(pip show "$pkg" 2>/dev/null | grep "Version:" | awk '{print $2}')
                log_info "  [ok] $pkg already installed (version: $installed_version)"
            else
                log_info "  [need] $pkg needs installation"
                needs_install=true
            fi
        fi
    done

    if [ "$needs_install" = true ]; then
        log_info "Installing Python packages: ${py_install}..."

        local packages="${py_install//,/ }"

        if pip install --no-cache-dir $packages; then
            log_info "Python packages installed successfully."
        else
            log_error "Failed to install Python packages!"
            return 1
        fi
    else
        log_info "All Python packages already installed."
    fi
}

# -----------------------------------------------------------------------------
# Step 5: NPM Package Installation (NPM_INSTALL)
# Stateless - checks if packages are installed at each startup
# -----------------------------------------------------------------------------
install_npm_packages() {
    local npm_install="${NPM_INSTALL:-}"

    if [ -z "$npm_install" ]; then
        log_info "NPM_INSTALL not set, skipping NPM package installation."
        return 0
    fi

    log_info "Checking NPM packages: ${npm_install}..."

    local needs_install=false
    IFS=',' read -ra PKG_ARRAY <<< "$npm_install"

    for pkg in "${PKG_ARRAY[@]}"; do
        pkg=$(echo "$pkg" | xargs)

        if [ -z "$pkg" ]; then
            continue
        fi

        if npm list -g "$pkg" --depth=0 &>/dev/null; then
            local installed_version
            installed_version=$(npm list -g "$pkg" --depth=0 2>/dev/null | grep "$pkg" | sed -n 's/.*@\([0-9.]*\).*/\1/p')
            log_info "  [ok] $pkg already installed (version: $installed_version)"
        else
            log_info "  [need] $pkg needs installation"
            needs_install=true
        fi
    done

    if [ "$needs_install" = true ]; then
        log_info "Installing NPM packages: ${npm_install}..."

        local packages="${npm_install//,/ }"

        if npm install -g $packages; then
            log_info "NPM packages installed successfully."
        else
            log_error "Failed to install NPM packages!"
            return 1
        fi
    else
        log_info "All NPM packages already installed."
    fi
}

# -----------------------------------------------------------------------------
# Step 6: Database Initialization with click-odoo-initdb
# Uses --unless-initialized to skip if DB already exists
# -----------------------------------------------------------------------------
initialize_database() {
    local initdb_options="${INITDB_OPTIONS:-}"

    if [ -z "$initdb_options" ]; then
        log_info "INITDB_OPTIONS not set, skipping database initialization."
        return 0
    fi

    log_info "Running click-odoo-initdb with options: ${initdb_options}..."

    if gosu odoo click-odoo-initdb -c "$ERP_CONF_PATH" $initdb_options; then
        log_info "Database initialization completed successfully."
    else
        local exit_code=$?
        log_warn "click-odoo-initdb exited with code ${exit_code}. This may be normal if the database already exists."
    fi
}

# -----------------------------------------------------------------------------
# Step 7: Automatic Module Upgrade with click-odoo-update
# Runs on every container restart when AUTO_UPGRADE=TRUE
# -----------------------------------------------------------------------------
run_auto_upgrade() {
    local auto_upgrade="${AUTO_UPGRADE:-FALSE}"
    auto_upgrade="${auto_upgrade^^}"

    if [ "$auto_upgrade" != "TRUE" ]; then
        log_info "AUTO_UPGRADE is not TRUE, skipping automatic upgrade."
        return 0
    fi

    # Build flags
    local update_flags=""
    local ignore_core="${UPGRADE_IGNORE_CORE:-TRUE}"
    ignore_core="${ignore_core^^}"
    if [ "$ignore_core" = "TRUE" ]; then
        update_flags="--ignore-core-addons"
        log_info "Ignoring core addons during upgrade (UPGRADE_IGNORE_CORE=TRUE)"
    fi

    # Discover databases
    local db_list="${ODOO_DB_NAME:-}"

    if [ -z "$db_list" ]; then
        log_info "ODOO_DB_NAME not set, discovering all Odoo databases..."

        local db_host db_port db_user db_password
        db_host=$(printenv 'conf.db_host' || echo 'db')
        db_port=$(printenv 'conf.db_port' || echo '5432')
        db_user=$(printenv 'conf.db_user' || echo 'odoo')
        db_password=$(printenv 'conf.db_password' || echo 'odoo')

        db_list=$(PGPASSWORD="$db_password" psql -h "$db_host" -p "$db_port" -U "$db_user" -d postgres -t -c \
            "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres', 'template0', 'template1') ORDER BY datname;" \
            2>/dev/null | xargs)

        if [ -z "$db_list" ]; then
            log_info "No Odoo databases found, skipping automatic upgrade."
            return 0
        fi

        local db_count
        db_count=$(echo "$db_list" | wc -w)
        log_info "Found ${db_count} database(s): ${db_list}"
    fi

    # Upgrade each database
    for db_name in $db_list; do
        log_info "--- Upgrading database: ${db_name} ---"

        # Check what needs updating (informational)
        log_info "Checking for module updates..."
        if gosu odoo click-odoo-update -c "$ERP_CONF_PATH" -d "$db_name" --if-exists $update_flags --list-only 2>&1 | tee /tmp/upgrade-list.log; then
            if grep -q "Updating addons for their hash changed" /tmp/upgrade-list.log 2>/dev/null; then
                log_info "Running upgrade for ${db_name}..."

                if gosu odoo click-odoo-update -c "$ERP_CONF_PATH" -d "$db_name" --if-exists $update_flags --i18n-overwrite; then
                    log_info "Database ${db_name} upgraded successfully."
                else
                    local exit_code=$?
                    log_warn "Upgrade of ${db_name} exited with code ${exit_code}. Continuing..."
                fi
            else
                log_info "Database ${db_name} is up-to-date."
            fi
        else
            log_warn "Failed to check ${db_name}. Skipping."
        fi

        rm -f /tmp/upgrade-list.log
    done

    log_info "All databases processed."
}

# -----------------------------------------------------------------------------
# Step 8: Fix report.url in all databases
# Ensures wkhtmltopdf can always fetch CSS/JS assets from inside the container
# regardless of what web.base.url is set to (e.g., https://mycompany.com)
# -----------------------------------------------------------------------------
fix_report_url() {
    local fix_enabled="${FIX_REPORT_URL:-FALSE}"
    fix_enabled="${fix_enabled^^}"

    if [ "$fix_enabled" != "TRUE" ]; then
        log_info "FIX_REPORT_URL is not TRUE, skipping report.url fix."
        return 0
    fi

    local odoo_port="${ODOO_PORT:-8069}"
    local report_url="http://localhost:${odoo_port}"

    local db_host db_port db_user db_password
    db_host=$(printenv 'conf.db_host' || echo 'db')
    db_port=$(printenv 'conf.db_port' || echo '5432')
    db_user=$(printenv 'conf.db_user' || echo 'odoo')
    db_password=$(printenv 'conf.db_password' || echo 'odoo')

    local db_list
    db_list=$(PGPASSWORD="$db_password" psql -h "$db_host" -p "$db_port" -U "$db_user" -d postgres -t -c \
        "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres', 'template0', 'template1') ORDER BY datname;" \
        2>/dev/null | xargs)

    if [ -z "$db_list" ]; then
        log_info "No databases found, skipping report.url fix."
        return 0
    fi

    for db_name in $db_list; do
        PGPASSWORD="$db_password" psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" -c \
            "INSERT INTO ir_config_parameter (key, value, create_uid, write_uid, create_date, write_date)
             VALUES ('report.url', '${report_url}', 1, 1, now(), now())
             ON CONFLICT (key) DO UPDATE SET value = '${report_url}', write_date = now();" \
            2>/dev/null && \
        log_info "  report.url = ${report_url} -> ${db_name}" || \
        log_warn "  Could not set report.url for ${db_name} (new database?)"
    done
}

# -----------------------------------------------------------------------------
# Step 9: Start Odoo
# Supports two modes:
#   Default: exec (Odoo becomes PID 1) - best signal handling
#   Watcher: managed process mode (RESOURCE_WATCHER=TRUE) - monitors resources
# -----------------------------------------------------------------------------

# Start Odoo as a background process (used by watcher mode)
start_odoo_background() {
    cd "$ODOO_SOURCE"
    gosu odoo python odoo-bin -c "$ERP_CONF_PATH" &
    ODOO_PID=$!
    log_info "Odoo started with PID ${ODOO_PID}"
}

# Resource watcher: monitors CPU/RAM changes and restarts Odoo
resource_watcher() {
    local check_interval="${RESOURCE_WATCHER_INTERVAL:-30}"
    local prev_cpus prev_ram

    prev_cpus=$(get_cpu_count)
    prev_ram=$(get_ram_bytes)

    log_info "Resource watcher active (checking every ${check_interval}s)"

    while true; do
        sleep "$check_interval"

        local curr_cpus curr_ram
        curr_cpus=$(get_cpu_count)
        curr_ram=$(get_ram_bytes)

        if [ "$curr_cpus" != "$prev_cpus" ] || [ "$curr_ram" != "$prev_ram" ]; then
            local prev_ram_mb=$(( prev_ram / 1024 / 1024 ))
            local curr_ram_mb=$(( curr_ram / 1024 / 1024 ))
            log_info "Resource change detected: CPU ${prev_cpus}->${curr_cpus}, RAM ${prev_ram_mb}MB->${curr_ram_mb}MB"

            # Recalculate and regenerate config
            compute_resources
            generate_config
            apply_resources

            # Gracefully restart Odoo
            if [ -n "${ODOO_PID:-}" ] && kill -0 "$ODOO_PID" 2>/dev/null; then
                log_info "Restarting Odoo with new configuration..."
                kill -TERM "$ODOO_PID" 2>/dev/null
                wait "$ODOO_PID" 2>/dev/null || true
                start_odoo_background
            fi

            prev_cpus="$curr_cpus"
            prev_ram="$curr_ram"
        fi
    done
}

start_odoo() {
    log_info "Starting Odoo ${ODOO_VERSION}..."

    local watcher_enabled="${RESOURCE_WATCHER:-FALSE}"
    watcher_enabled="${watcher_enabled^^}"

    if [ "$watcher_enabled" = "TRUE" ]; then
        # Managed mode: entrypoint stays as PID 1, Odoo runs in background
        log_info "Resource watcher enabled - running in managed process mode"

        # Trap signals and forward to Odoo
        trap 'log_info "Received shutdown signal"; [ -n "${ODOO_PID:-}" ] && kill -TERM "$ODOO_PID" 2>/dev/null; [ -n "${WATCHER_PID:-}" ] && kill "$WATCHER_PID" 2>/dev/null; wait; exit 0' SIGTERM SIGINT SIGQUIT

        start_odoo_background

        # Start resource watcher in background
        resource_watcher &
        WATCHER_PID=$!

        # Wait for Odoo to exit
        wait "$ODOO_PID"
        local exit_code=$?

        # Clean up watcher
        kill "$WATCHER_PID" 2>/dev/null || true
        wait "$WATCHER_PID" 2>/dev/null || true

        exit "$exit_code"
    else
        # Default mode: exec Odoo as PID 1 (best signal handling)
        cd "$ODOO_SOURCE"
        exec gosu odoo python odoo-bin -c "$ERP_CONF_PATH" "$@"
    fi
}

# -----------------------------------------------------------------------------
# Main Entrypoint Logic
# -----------------------------------------------------------------------------
main() {
    log_info "=========================================="
    log_info "jdoo - Odoo ${ODOO_VERSION} Starting..."
    log_info "Python: $(python --version 2>&1)"
    log_info "=========================================="

    if [ "$(id -u)" != "0" ]; then
        log_error "This entrypoint must be run as root for proper user/permission handling."
        exit 1
    fi

    set_state "STARTING"

    # Step 1: Setup user permissions (PUID/PGID)
    setup_user_permissions

    # Step 2: Auto-compute resource allocation (workers, memory limits)
    compute_resources

    # Step 3: Generate Odoo configuration from conf.* env vars
    generate_config

    # Apply computed resources to erp.conf (after config generation)
    apply_resources

    # Step 4: Install Python packages
    install_python_packages

    # Step 5: Install NPM packages
    install_npm_packages

    # Step 6: Initialize database if INITDB_OPTIONS is set
    set_state "INITIALIZING"
    initialize_database

    # Step 7: Run automatic upgrade if AUTO_UPGRADE=TRUE
    set_state "UPGRADING"
    run_auto_upgrade

    # Step 8: Fix report.url for wkhtmltopdf PDF reports
    fix_report_url

    # Step 9: Start Odoo or execute custom command
    set_state "RUNNING"
    case "${1:-}" in
        odoo|odoo-bin|"")
            # Strip "odoo" or "odoo-bin" prefix if present
            if [ "${1:-}" = "odoo" ] || [ "${1:-}" = "odoo-bin" ]; then
                shift
            fi
            start_odoo "$@"
            ;;
        -*)
            # Arguments starting with '-' are Odoo options
            start_odoo "$@"
            ;;
        *)
            # Non-Odoo command (bash, psql, etc.) - exec directly
            log_info "Executing custom command: $*"
            exec gosu odoo "$@"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Execute Main Function
# -----------------------------------------------------------------------------
main "$@"
