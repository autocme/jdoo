#!/bin/bash
# =============================================================================
# swap-setup.sh — Auto-configure Swap Memory (50% of RAM)
# =============================================================================
# Detects system RAM and creates a swap file at 50% of total RAM.
# Safe to run multiple times — skips if swap is already configured.
#
# Usage:
#   sudo ./swap-setup.sh          # Auto: 50% of RAM
#   sudo ./swap-setup.sh 2G       # Manual: 2GB swap
#   sudo ./swap-setup.sh 512M     # Manual: 512MB swap
#
# This script runs on the HOST server, not inside containers.
# All Docker containers automatically benefit from host swap.
# =============================================================================

set -euo pipefail

SWAP_FILE="/swapfile"
SWAPPINESS="${SWAP_SWAPPINESS:-60}"

log_info() {
    echo "[swap-setup] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warn() {
    echo "[swap-setup] $(date '+%Y-%m-%d %H:%M:%S') - WARN: $*" >&2
}

log_error() {
    echo "[swap-setup] $(date '+%Y-%m-%d %H:%M:%S') - ERROR: $*" >&2
}

# Check root
if [ "$(id -u)" != "0" ]; then
    log_error "Must be run as root (sudo ./swap-setup.sh)"
    exit 1
fi

# Detect current swap
current_swap_mb=$(free -m | awk '/^Swap:/ {print $2}')
if [ "${current_swap_mb:-0}" -gt 0 ]; then
    log_info "Swap already active: ${current_swap_mb}MB"
    log_info "To reconfigure, first run: swapoff -a && rm -f ${SWAP_FILE}"
    swapon --show
    exit 0
fi

# Determine swap size
if [ -n "${1:-}" ]; then
    # Manual size specified (e.g., 2G, 512M)
    SWAP_SIZE="$1"
    log_info "Using specified swap size: ${SWAP_SIZE}"
else
    # Auto-compute: 50% of RAM
    total_ram_mb=$(free -m | awk '/^Mem:/ {print $2}')
    swap_size_mb=$(( total_ram_mb / 2 ))

    # Minimum 256MB, maximum 8GB
    [ "$swap_size_mb" -lt 256 ] && swap_size_mb=256
    [ "$swap_size_mb" -gt 8192 ] && swap_size_mb=8192

    if [ "$swap_size_mb" -ge 1024 ]; then
        SWAP_SIZE="$(( swap_size_mb / 1024 ))G"
    else
        SWAP_SIZE="${swap_size_mb}M"
    fi
    log_info "Auto-computed: ${total_ram_mb}MB RAM → ${SWAP_SIZE} swap (50%)"
fi

# Check disk space
log_info "Creating swap file: ${SWAP_FILE} (${SWAP_SIZE})..."

# Create swap file
if command -v fallocate &>/dev/null; then
    fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}"
else
    # fallocate not available (some filesystems), use dd
    # Parse size to bytes for dd
    size_val="${SWAP_SIZE%[GMgm]}"
    size_unit="${SWAP_SIZE: -1}"
    case "$size_unit" in
        G|g) dd_count=$(( size_val * 1024 )) ;;
        M|m) dd_count=$size_val ;;
        *) log_error "Invalid size format: ${SWAP_SIZE}"; exit 1 ;;
    esac
    dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${dd_count}" status=progress
fi

# Secure permissions (swap should only be readable by root)
chmod 600 "${SWAP_FILE}"

# Format as swap
mkswap "${SWAP_FILE}"

# Enable swap
swapon "${SWAP_FILE}"

# Set swappiness
sysctl vm.swappiness="${SWAPPINESS}" >/dev/null

# Make persistent across reboots
if ! grep -q "${SWAP_FILE}" /etc/fstab 2>/dev/null; then
    echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
    log_info "Added to /etc/fstab for persistence"
fi

# Make swappiness persistent
if ! grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
    echo "vm.swappiness=${SWAPPINESS}" >> /etc/sysctl.conf
elif grep -q "^vm.swappiness" /etc/sysctl.conf; then
    sed -i "s/^vm.swappiness=.*/vm.swappiness=${SWAPPINESS}/" /etc/sysctl.conf
fi

# Verify
log_info "Swap configured successfully:"
log_info "  File: ${SWAP_FILE}"
log_info "  Size: ${SWAP_SIZE}"
log_info "  Swappiness: ${SWAPPINESS}"
free -h | grep -E "^(Mem|Swap):" | while read -r line; do
    log_info "  $line"
done
