#!/usr/bin/env bash
# Finding #18 — the existing-database verification probe failed OPEN.
#
# When a tenant DB exists but carries no init sentinel, the script probes it to
# tell three states apart: healthy, empty-and-pre-created, half-initialized. A
# single failed `psql` connection sent it down a fourth path that logged
# "Proceeding to serve it as before" and started Odoo anyway.
#
# That was never a real option. A database this script cannot reach is one Odoo
# cannot reach either, so the fallback did not rescue anything — it traded an
# explicit error for an opaque one: the container reported healthy, answered the
# health check, and served 500s. And an unverified database may be exactly the
# half-initialized case the block exists to catch.
#
# The probe now retries (PostgreSQL may be starting, recovering, or briefly at
# max_connections) and only then fails closed with DB_UNREACHABLE.
#
# Path matrix
#   normal       -> a reachable DB is classified as before (no behaviour change)
#   boundary     -> succeeds on the last allowed attempt; attempts=1
#   failure      -> unreachable after all attempts => non-zero exit, not serving
#   retry        -> a transient outage that clears is survived silently
#   permission   -> N/A (the probe uses the tenant's own role; no privilege step)
#   concurrency  -> N/A (one boot, one process, before Odoo starts)
#   rollback     -> N/A (the probe writes nothing; it only classifies)
#   idempotency  -> repeated boots against the same DB reach the same verdict

source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

load_functions _init_sentinel _write_init_sentinel _addons_path_has_modules \
              initialize_database

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

setup_env() {
    ODOO_DATA_DIR="${WORK}/data"; mkdir -p "$ODOO_DATA_DIR"
    rm -f "${ODOO_DATA_DIR}"/.db-init-complete.*
    ERP_CONF_PATH="${WORK}/erp.conf"; : > "$ERP_CONF_PATH"
    ODOO_SOURCE="${WORK}/src"; mkdir -p "$ODOO_SOURCE"
    export INIT_DB="qatenant" DB_PROBE_ATTEMPTS=3 DB_PROBE_DELAY=0
    export STATE_FILE="${WORK}/state"
    unset INIT_MODULES INITDB_OPTIONS
}

# Capture both the exit code and the recorded state.
run_probe() {
    initialize_database >"${WORK}/out" 2>&1
    echo "$?"
}

state_now() { cat "${WORK}/state" 2>/dev/null || echo ""; }

describe "#18 — an unreachable database must fail closed"

it "returns non-zero instead of serving an unverifiable database"
setup_env
fake_psql_unreachable
# The existence probe must say "exists" while the verification probe fails, so
# the flow reaches the block under test. `fake_psql_unreachable` fails both,
# which lands on the "does not exist" path — so make existence succeed once.
fake_bin psql "
    marker='${WORK}/.exists_done'
    if [ ! -f \"\$marker\" ]; then touch \"\$marker\"; echo 1; exit 0; fi
    echo 'psql: could not connect to server' >&2; exit 2"
rc=$(run_probe)
assert_failure "$rc"

it "records DB_UNREACHABLE rather than a misleading healthy state"
assert_contains "$(state_now)" "DB_UNREACHABLE"

it "says so in the log instead of claiming it will serve as before"
assert_contains "$(cat "${WORK}/out")" "Cannot reach existing DB"

it "no longer claims it is proceeding to serve the database"
assert_not_contains "$(cat "${WORK}/out")" "Proceeding to serve it as before"

describe "retry — a transient outage is survived, not punished"

it "succeeds when the database becomes reachable within the attempt budget"
setup_env
rm -f "${WORK}/.exists_done"
# 1st call = existence probe (ok). Calls 2-3 fail. Call 4 onward succeed with
# base='installed', which is the healthy classification.
fake_bin psql "
    counter='${WORK}/.calls'; printf 'x' >> \"\$counter\"
    calls=\$(wc -c < \"\$counter\" | tr -d ' ')
    if [ \"\$calls\" -eq 1 ]; then echo 1; exit 0; fi
    if [ \"\$calls\" -le 3 ]; then echo 'psql: starting up' >&2; exit 2; fi
    echo installed; exit 0"
rm -f "${WORK}/.calls"
rc=$(run_probe)
assert_success "$rc"

it "reports how many retries it needed"
assert_contains "$(cat "${WORK}/out")" "after"

it "actually retried rather than succeeding on the first try"
calls=$(wc -c < "${WORK}/.calls" | tr -d ' ')
assert_gt "$calls" 3

describe "normal — a reachable database is classified exactly as before"

it "an installed base is served and the sentinel is backfilled"
setup_env
rm -f "${WORK}/.exists_done" "${WORK}/.calls"
fake_psql_returning "installed"
rc=$(run_probe)
assert_success "$rc"

it "the backfilled sentinel exists"
if ls "${ODOO_DATA_DIR}"/.db-init-complete.* >/dev/null 2>&1; then pass; else
    fail "sentinel was not written for a verified healthy DB"
fi

describe "boundary"

it "a single-attempt budget still fails closed rather than serving"
setup_env
DB_PROBE_ATTEMPTS=1
rm -f "${WORK}/.exists_done"
fake_bin psql "
    marker='${WORK}/.exists_done'
    if [ ! -f \"\$marker\" ]; then touch \"\$marker\"; echo 1; exit 0; fi
    exit 2"
rc=$(run_probe)
assert_failure "$rc"

it "an existing sentinel short-circuits the probe entirely"
setup_env
rm -f "${WORK}/.exists_done"
_write_init_sentinel "$INIT_DB" >/dev/null 2>&1
fake_psql_returning "1"
rc=$(run_probe)
assert_success "$rc"

describe "idempotency"

it "two consecutive boots against a healthy DB reach the same verdict"
setup_env
rm -f "${WORK}/.exists_done"
fake_psql_returning "installed"
first=$(run_probe)
second=$(run_probe)
assert_equals "$second" "$first"

finish
