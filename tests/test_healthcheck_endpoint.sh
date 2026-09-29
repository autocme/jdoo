#!/usr/bin/env bash
# The container healthcheck was blind in both directions (fixed 2026-09-29).
#
# It ran `curl -f http://localhost:8069/web/login`, and:
#   * /web/login never rendered. web_login() calls ensure_db(), which calls
#     db_list(force=True) and then ABORTS with a redirect — 302 to the same URL,
#     or 303 to /web/database/selector when no database matched the `Host:`
#     header a healthcheck sends. `curl -f` only fails on >= 400, so a 303
#     meaning "your database could not be resolved" scored HEALTHY.
#   * With PostgreSQL dead, db_list swallows the OperationalError, returns [],
#     and the endpoint still 303s → exit 0. A dead database read as healthy.
#   * It cost two db_connect('postgres') calls and a session-file write every
#     15s per tenant — and sessions on that maintenance database are exactly
#     what saturated the shared pooler on 2026-09-28 and took every tenant's
#     login down at once.
#
# The replacement is two probes: /web/health for the WSGI stack (auth='none',
# save_session=False, in the nodb routing map so it CANNOT prove the database),
# then a db-only route (auth='public' ⇒ excluded from the nodb map ⇒ 404 on a
# broken registry). Both compared to an EXACT 200.
#
# These tests run the script's OWN functions against a fake curl. Only
# hc_process_alive is stubbed, because it scans the real /proc and its verdict
# would depend on whatever happens to run on the test host.
#
# Path matrix
#   normal      -> both probes 200 → RUNNING, exit 0
#   boundary    -> the exact regression: 303 must NOT be healthy
#   failure     -> layer 2 fails (000/500) and layer 3 fails (404) separately
#   permission  -> N/A (auth='none' / auth='public' endpoints, no credentials)
#   retry       -> N/A (Docker's retries/start_period own that)
#   concurrency -> N/A (one probe per interval)
#   rollback    -> N/A
#   idempotency -> two consecutive healthy runs give the same verdict

source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HC="${ROOT}/healthcheck.sh"
COMPOSE="${ROOT}/docker-compose.yml"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STATE_FILE="${WORK}/.container-state"
ODOO_PORT=8069
HC_HOST=127.0.0.1
HC_DB_PATH="/web/service-worker.js"
HC_TIMEOUT=5
export STATE_FILE ODOO_PORT HC_HOST HC_DB_PATH HC_TIMEOUT

load_functions_from "$HC" hc_status hc_main

# A curl whose -w '%{http_code}' output is scripted per URL path. Every other
# behaviour (flags, ordering) is the script's own.
fake_curl_codes() {
    local health="$1" dbpath="$2"
    fake_bin curl "
url=\"\${!#}\"
case \"\$url\" in
  */web/health*) printf '%s' '${health}' ;;
  *${HC_DB_PATH}*) printf '%s' '${dbpath}' ;;
  *) printf '%s' '404' ;;
esac
exit 0"
}

# Run the real hc_main in a subshell (it exits) with the process layer stubbed.
run_hc() {
    ( hc_process_alive() { return 0; }; hc_main ) 2>&1
}
run_hc_code() {
    ( hc_process_alive() { return 0; }; hc_main ) >/dev/null 2>&1
    echo $?
}

describe "the endpoint choice is the fix, so pin it"

# CODE only. The script carries a long comment block recording why /web/login and
# db_server_status are wrong, and an assertion that counted those mentions would
# force the explanation out of the file to stay green.
hc_code() { grep -vE '^[[:space:]]*#' "$HC"; }

it "/web/login is gone from the healthcheck"
# It never rendered, and it opened two `postgres` sessions per probe.
assert_equals "$(hc_code | grep -c '/web/login')" "0"

it "/web/health is probed"
assert_contains "$(hc_code)" "/web/health"

it "db_server_status is never requested"
# That variant does db_connect('postgres') — the one database we are protecting —
# every 15s per tenant.
assert_equals "$(hc_code | grep -c 'db_server_status')" "0"

it "a database-touching route is probed too"
# /web/health is auth='none' ⇒ in the nodb routing map ⇒ answers 200 with a dead
# registry. Without a second probe the check cannot see a dead database.
assert_contains "$(cat "$HC")" "HC_DB_PATH"

it "the db path is overridable for a future core rename"
assert_contains "$(cat "$HC")" 'HC_DB_PATH:-/web/service-worker.js'

it "the status is compared exactly, not through curl -f"
assert_contains "$(cat "$HC")" "%{http_code}"

it "no probe relies on curl -f"
assert_equals "$(hc_code | grep -cE 'curl [^|]*-f ')" "0"

describe "normal — a healthy tenant"

echo RUNNING > "$STATE_FILE"

it "both probes 200 gives RUNNING"
fake_curl_codes 200 200
assert_contains "$(run_hc)" "RUNNING"

it "and exits 0"
assert_equals "$(run_hc_code)" "0"

it "two consecutive runs agree"
a="$(run_hc)"; b="$(run_hc)"
assert_equals "$a" "$b"

describe "boundary — THE regression: a redirect is not health"

it "303 to the database selector is unhealthy"
# This is the exact hole: `curl -f` passed on it for months.
fake_curl_codes 303 200
assert_equals "$(run_hc_code)" "1"

it "and it says which code it got"
assert_contains "$(run_hc)" "303"

it "302 (session database mismatch) is unhealthy too"
fake_curl_codes 302 200
assert_equals "$(run_hc_code)" "1"

describe "failure — each layer fails on its own terms"

it "a refused connection on layer 2 is RUNNING_LOADING"
fake_curl_codes 000 200
assert_contains "$(run_hc)" "RUNNING_LOADING"

it "a 500 on layer 2 is not healthy"
fake_curl_codes 500 200
assert_equals "$(run_hc_code)" "1"

it "a 404 on the db route is RUNNING_DB_UNREACHABLE"
# _serve_nodb has no route for an auth='public' endpoint, so a broken registry
# answers 404 here while /web/health still answers 200.
fake_curl_codes 200 404
assert_contains "$(run_hc)" "RUNNING_DB_UNREACHABLE"

it "and it exits 1"
fake_curl_codes 200 404
assert_equals "$(run_hc_code)" "1"

it "a dead database is not reported as RUNNING"
fake_curl_codes 200 404
assert_not_contains "$(run_hc)" "^RUNNING$"

describe "the other states still behave"

it "STARTING is unhealthy"
echo STARTING > "$STATE_FILE"
fake_curl_codes 200 200
assert_contains "$(run_hc)" "STARTING"

it "DB_INCOMPLETE is unhealthy"
echo DB_INCOMPLETE > "$STATE_FILE"
assert_equals "$(run_hc_code)" "1"

it "UPGRADE_FAILED is unhealthy"
echo UPGRADE_FAILED > "$STATE_FILE"
assert_equals "$(run_hc_code)" "1"

it "a missing state file is UNKNOWN, not healthy"
rm -f "$STATE_FILE"
assert_contains "$(run_hc)" "UNKNOWN"

describe "the container actually runs this script"

it "the compose healthcheck calls healthcheck.sh"
assert_contains "$(cat "$COMPOSE")" "/usr/local/bin/healthcheck.sh"

it "start_period still covers a long first boot"
sp=$(grep -A6 'test: \["CMD", "/usr/local/bin/healthcheck.sh"\]' "$COMPOSE" \
     | grep -oE 'start_period: [0-9]+s' | grep -oE '[0-9]+')
assert_ge "${sp:-0}" 300

finish
