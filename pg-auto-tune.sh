#!/bin/sh
# =============================================================================
# pg-auto-tune.sh — PostgreSQL Auto-Tuning Entrypoint Wrapper
# =============================================================================
# Wraps the default PostgreSQL Docker entrypoint with automatic resource tuning.
# Reads container RAM and computes optimal PostgreSQL settings.
#
# All values are overridable via environment variables:
#   PG_SHARED_BUFFERS, PG_EFFECTIVE_CACHE_SIZE, PG_WORK_MEM,
#   PG_MAINTENANCE_WORK_MEM, PG_MAX_CONNECTIONS
#
# Usage (docker-compose.yml):
#   entrypoint: ["/usr/local/bin/pg-auto-tune.sh"]
#   volumes:
#     - ./pg-auto-tune.sh:/usr/local/bin/pg-auto-tune.sh:ro
# =============================================================================

set -eu

# -----------------------------------------------------------------------------
# Detect container RAM (MB)
# -----------------------------------------------------------------------------
get_ram_mb() {
    # Method 1: cgroup v2 memory.max
    if [ -f /sys/fs/cgroup/memory.max ]; then
        mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "max")
        if [ "$mem_max" != "max" ] && [ "$mem_max" -gt 0 ] 2>/dev/null; then
            echo $((mem_max / 1024 / 1024))
            return
        fi
    fi

    # Method 2: cgroup v1 memory limit
    if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        mem_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo "0")
        # cgroup v1 uses ~9.2 EB when unlimited
        if [ "$mem_limit" -gt 0 ] 2>/dev/null && [ "$mem_limit" -lt 9223372036854771712 ] 2>/dev/null; then
            echo $((mem_limit / 1024 / 1024))
            return
        fi
    fi

    # Method 3: /proc/meminfo fallback
    ram_kb=$(grep "^MemTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}')
    if [ -n "$ram_kb" ] && [ "$ram_kb" -gt 0 ] 2>/dev/null; then
        echo $((ram_kb / 1024))
        return
    fi

    # Fallback: 2GB
    echo 2048
}

# -----------------------------------------------------------------------------
# Compute PostgreSQL tuning parameters
# -----------------------------------------------------------------------------
RAM_MB=$(get_ram_mb)

# PG_SHARED_BUFFERS: min(25% RAM, 4096MB), min 128MB
if [ -z "${PG_SHARED_BUFFERS:-}" ]; then
    SB=$((RAM_MB / 4))
    [ "$SB" -gt 4096 ] && SB=4096
    [ "$SB" -lt 128 ] && SB=128
    PG_SHARED_BUFFERS="${SB}MB"
fi

# PG_EFFECTIVE_CACHE_SIZE: 50% RAM, min 256MB
if [ -z "${PG_EFFECTIVE_CACHE_SIZE:-}" ]; then
    ECS=$((RAM_MB / 2))
    [ "$ECS" -lt 256 ] && ECS=256
    PG_EFFECTIVE_CACHE_SIZE="${ECS}MB"
fi

# PG_WORK_MEM: 64MB default
if [ -z "${PG_WORK_MEM:-}" ]; then
    PG_WORK_MEM="64MB"
fi

# PG_MAINTENANCE_WORK_MEM: min(10% RAM, 2048MB), min 64MB
if [ -z "${PG_MAINTENANCE_WORK_MEM:-}" ]; then
    MWM=$((RAM_MB / 10))
    [ "$MWM" -gt 2048 ] && MWM=2048
    [ "$MWM" -lt 64 ] && MWM=64
    PG_MAINTENANCE_WORK_MEM="${MWM}MB"
fi

# PG_MAX_CONNECTIONS: default 100
if [ -z "${PG_MAX_CONNECTIONS:-}" ]; then
    PG_MAX_CONNECTIONS="100"
fi

# -----------------------------------------------------------------------------
# Log computed values
# -----------------------------------------------------------------------------
echo "[pg-auto-tune] RAM: ${RAM_MB}MB | shared=${PG_SHARED_BUFFERS} | cache=${PG_EFFECTIVE_CACHE_SIZE} | work=${PG_WORK_MEM} | maint=${PG_MAINTENANCE_WORK_MEM} | conn=${PG_MAX_CONNECTIONS}"

# -----------------------------------------------------------------------------
# Start PostgreSQL with computed tuning flags
# Calls the original Docker entrypoint (docker-entrypoint.sh)
# -----------------------------------------------------------------------------
exec docker-entrypoint.sh postgres \
    -c shared_buffers="${PG_SHARED_BUFFERS}" \
    -c effective_cache_size="${PG_EFFECTIVE_CACHE_SIZE}" \
    -c work_mem="${PG_WORK_MEM}" \
    -c maintenance_work_mem="${PG_MAINTENANCE_WORK_MEM}" \
    -c max_connections="${PG_MAX_CONNECTIONS}" \
    "$@"
