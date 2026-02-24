#!/bin/bash
# =============================================================================
# compute-env.sh - Auto-compute PYTHON_VERSION & PG_VERSION from ODOO_VERSION
# =============================================================================
# Reads ODOO_VERSION (from environment or .env), computes the matching
# PYTHON_VERSION and PG_VERSION, and writes them to .env.
#
# Version Matrix:
#   ODOO 15-16  → Python 3.10, PG 14-15
#   ODOO 17-18  → Python 3.12, PG 16
#   ODOO 19+    → Python 3.12, PG 17
#
# Usage:
#   bash compute-env.sh              # writes computed values to .env
#   source compute-env.sh            # also exports to current shell
#
# Dokploy:
#   Set as Pre-Deploy Command: bash compute-env.sh
#
# Idempotent: safe to run multiple times. Re-computes on ODOO_VERSION change.
# Override: set PYTHON_VERSION or PG_VERSION in environment (Dokploy UI)
#           to skip auto-computation for that variable.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"

# Save any environment-level overrides (from Dokploy UI, shell export, etc.)
# These take priority — if set, we won't overwrite them.
_ENV_PYTHON_VERSION="${PYTHON_VERSION:-}"
_ENV_PG_VERSION="${PG_VERSION:-}"

# Load .env
if [ ! -f .env ]; then
    echo "[compute-env] ERROR: .env not found. Copy .env.example first."
    exit 1
fi

# Read ODOO_VERSION from .env (env var takes precedence if already set)
if [ -z "${ODOO_VERSION:-}" ]; then
    ODOO_VERSION=$(grep "^ODOO_VERSION=" .env | head -1 | cut -d= -f2 | tr -d '"'"'"' ')
fi
ODOO_VERSION="${ODOO_VERSION:-19.0}"
MAJOR="${ODOO_VERSION%%.*}"

echo "[compute-env] ODOO_VERSION=${ODOO_VERSION} (major: ${MAJOR})"

# ---------------------------------------------------------------------------
# Compute PYTHON_VERSION
# ---------------------------------------------------------------------------
if [ -n "$_ENV_PYTHON_VERSION" ]; then
    COMPUTED_PY="$_ENV_PYTHON_VERSION"
    echo "[compute-env] PYTHON_VERSION=${COMPUTED_PY} (from environment override)"
elif [ "$MAJOR" -le 16 ]; then
    COMPUTED_PY="3.10"
    echo "[compute-env] PYTHON_VERSION=${COMPUTED_PY} (auto: Odoo ≤16 → Python 3.10)"
else
    COMPUTED_PY="3.12"
    echo "[compute-env] PYTHON_VERSION=${COMPUTED_PY} (auto: Odoo ≥17 → Python 3.12)"
fi

# ---------------------------------------------------------------------------
# Compute PG_VERSION
# ---------------------------------------------------------------------------
if [ -n "$_ENV_PG_VERSION" ]; then
    COMPUTED_PG="$_ENV_PG_VERSION"
    echo "[compute-env] PG_VERSION=${COMPUTED_PG} (from environment override)"
else
    case "$MAJOR" in
        15)    COMPUTED_PG="14" ;;
        16)    COMPUTED_PG="15" ;;
        17|18) COMPUTED_PG="16" ;;
        *)     COMPUTED_PG="17" ;;
    esac
    echo "[compute-env] PG_VERSION=${COMPUTED_PG} (auto: Odoo ${MAJOR} → PG ${COMPUTED_PG})"
fi

# ---------------------------------------------------------------------------
# Write to .env (update existing line or append)
# ---------------------------------------------------------------------------
update_env() {
    local key="$1" value="$2"
    if grep -q "^${key}=" .env; then
        # Update existing line
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    elif grep -q "^#${key}=" .env; then
        # Uncomment and set
        sed -i "s|^#${key}=.*|${key}=${value}|" .env
    elif grep -q "^# *${key}=" .env; then
        # Uncomment (with space after #) and set
        sed -i "s|^# *${key}=.*|${key}=${value}|" .env
    else
        # Append
        echo "${key}=${value}" >> .env
    fi
}

update_env "PYTHON_VERSION" "$COMPUTED_PY"
update_env "PG_VERSION" "$COMPUTED_PG"

# Export for current shell (when used with `source`)
export PYTHON_VERSION="$COMPUTED_PY"
export PG_VERSION="$COMPUTED_PG"

echo "[compute-env] Done. .env updated."
