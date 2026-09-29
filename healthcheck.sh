#!/bin/sh
# =============================================================================
# jdoo - Smart Healthcheck Script
# =============================================================================
# Reads container state from a file written by entrypoint.sh.
# Returns healthy (exit 0) ONLY when Odoo HTTP is actually responding AND the
# tenant database is reachable.
#
# States:
#   STARTING             → exit 1 (entrypoint initializing — not ready)
#   INITIALIZING         → exit 1 (database initialization in progress)
#   UPGRADING            → exit 1 (module upgrade in progress)
#   RUNNING              → exit 0 (process alive, HTTP 200, database reachable)
#   RUNNING_NO_PROCESS   → exit 1 (Odoo process not found — crashed)
#   RUNNING_LOADING      → exit 1 (process alive, HTTP not answering 200 yet)
#   RUNNING_DB_UNREACHABLE → exit 1 (HTTP answers but the registry is unusable)
#   DB_INCOMPLETE        → exit 1 (init interrupted / addons missing)
#   UPGRADE_FAILED       → exit 1 (module upgrade failed)
#   UNKNOWN              → exit 1 (state file missing or unrecognized)
#
# -----------------------------------------------------------------------------
# WHY TWO PROBES, AND WHY NOT /web/login (changed 2026-09-29)
#
# The old probe was `curl -f .../web/login`, and it was blind in both directions:
#
#   * It never reached the login page. `web_login()` calls `ensure_db()`, which
#     calls `db_list(force=True)` and then ABORTS with a redirect — 302 to the
#     same URL, or 303 to /web/database/selector when no database matched the
#     `Host: localhost` header a healthcheck sends. `curl -f` only fails on >=400,
#     so a 303 "your database could not be resolved" scored HEALTHY. That is why
#     this script now compares the EXACT status code and demands 200.
#   * With PostgreSQL entirely dead, `db_list` swallows the OperationalError,
#     returns [], and the endpoint still 303s → exit 0. It could not detect a
#     dead database either.
#   * It cost two `db_connect('postgres')` calls and one session file WRITE every
#     15 seconds, per tenant. Those maintenance-database sessions are exactly
#     what saturated the shared pooler on 2026-09-28 and took every tenant's
#     login down at once.
#
# You cannot prove a database is alive without touching it, so the tenant-DB
# touch is the POINT of layer 3 — but it reuses a connection already in the
# worker's pool and never touches `postgres`.
#
#   Layer 2  /web/health          auth='none', save_session=False, no QWeb
#                                 render, no db_list. Proves the WSGI stack
#                                 answers. It is NOT a database check: being
#                                 auth='none' it lives in the nodb routing map,
#                                 so it answers 200 with a dead registry.
#                                 🔴 Never pass db_server_status=1 — that opens a
#                                 cursor on `postgres`, the one database we are
#                                 protecting, every 15s per tenant.
#   Layer 3  /web/service-worker.js  auth='public' ⇒ EXCLUDED from the nodb
#                                 routing map (http.py: `if nodb_only and
#                                 auth != "none": continue`), readonly=True, and
#                                 its body is a static file read. DB alive → 200.
#                                 Registry unusable → RegistryError → _serve_nodb
#                                 → no match → 404. Chosen over
#                                 /web/manifest.webmanifest, which runs four ORM
#                                 searches per probe.
#
# Override with HC_DB_PATH if a future Odoo renames that route.
# =============================================================================

STATE_FILE="${STATE_FILE:-/var/lib/odoo/.container-state}"
ODOO_PORT="${ODOO_PORT:-8069}"
HC_HOST="${HC_HOST:-127.0.0.1}"
HC_DB_PATH="${HC_DB_PATH:-/web/service-worker.js}"
HC_TIMEOUT="${HC_TIMEOUT:-5}"

# Is any odoo-bin process alive? /proc, because pgrep is absent from slim images.
hc_process_alive() {
    for cmdline_file in /proc/[0-9]*/cmdline; do
        if grep -ql "odoo-bin" "$cmdline_file" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Print the EXACT HTTP status for a path, or 000 when the connection failed.
# Deliberately not `curl -f`: that only fails on >=400, which is how the old
# probe scored a 303 redirect to the database selector as healthy.
hc_status() {
    code=$(curl -s -o /dev/null --max-time "$HC_TIMEOUT" \
           -w '%{http_code}' "http://${HC_HOST}:${ODOO_PORT}$1" 2>/dev/null) || code=000
    [ -n "$code" ] || code=000
    printf '%s' "$code"
}

hc_main() {
    STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "")

    case "$STATE" in
        STARTING|INITIALIZING|UPGRADING|UPGRADE_RETRY)
            echo "$STATE"
            exit 1
            ;;
        RUNNING)
            # Layer 1: process
            if ! hc_process_alive; then
                echo "RUNNING_NO_PROCESS"
                exit 1
            fi

            # Layer 2: the WSGI stack answers
            code=$(hc_status /web/health)
            if [ "$code" != "200" ]; then
                echo "RUNNING_LOADING(${code})"
                exit 1
            fi

            # Layer 3: the tenant database is reachable
            code=$(hc_status "$HC_DB_PATH")
            if [ "$code" != "200" ]; then
                echo "RUNNING_DB_UNREACHABLE(${code})"
                exit 1
            fi

            echo "RUNNING"
            exit 0
            ;;
        DB_INCOMPLETE)
            # A previous DB init was interrupted, or the shared addons volume is
            # empty → the DB is half-created / non-functional. Report unhealthy so
            # the platform never treats this tenant as ready. (entrypoint refuses
            # to serve it; no data is dropped.)
            echo "DB_INCOMPLETE"
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
}

hc_main
