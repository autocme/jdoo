#!/usr/bin/env bash
# Tenants ran with Odoo's default db_maxconn of 64 and no gevent variant
# (fixed 2026-09-29).
#
# db_maxconn sizes each PROCESS's own client-side connection pool
# (odoo/sql_db.py keeps one per process, plus a readonly one), and in
# pool_mode=session every OPEN client connection holds a PgBouncer server slot
# for its whole life. With the upstream default, one tenant's pathological worst
# case is (workers + cron + gevent) x 64 client connections against a pooler
# whose per-tenant ceiling is 15 — i.e. there was no bound at all on the tenant
# side. Normal usage is driven by concurrency (a production tenant measures 6-9
# server connections in total), so this is a bound on the pathological case.
#
# The gevent variant matters on its own: without db_maxconn_gevent, the gevent
# worker inherits db_maxconn (sql_db.py), and it is the one process serving many
# concurrent greenlets — lowering the shared ceiling would strangle the websocket
# bus.
#
# Path matrix
#   normal       -> the defaults land in erp.conf
#   boundary     -> the default must satisfy the cross-file pooler invariant
#   failure      -> an operator-set conf.db_maxconn must NOT be overwritten
#   permission   -> N/A (no privilege boundary in a resource calculation)
#   retry        -> N/A (pure computation + one append)
#   concurrency  -> the ceiling IS the concurrency bound; asserted
#   rollback     -> N/A (rollback is a redeploy)
#   idempotency  -> applying twice leaves one line, not two

source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

load_functions get_cpu_count get_ram_bytes parse_cpuset compute_resources apply_resources

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGB_INI="${ROOT}/shared-pg-stack/pgbouncer.ini"
TENANT_COMPOSE="${ROOT}/docker-compose.yml"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MB=1048576
GB=1073741824

# Same shape as test_memory_limits.sh: drive the computation with a chosen
# RAM/CPU, and clear every override so the DEFAULT path is what runs.
compute_with() {
    FAKE_RAM_BYTES="$1"
    FAKE_CPU_COUNT="$2"
    get_ram_bytes() { echo "$FAKE_RAM_BYTES"; }
    get_cpu_count() { echo "$FAKE_CPU_COUNT"; }
    unset WORKERS MAX_CRON_THREADS LIMIT_MEMORY_SOFT LIMIT_MEMORY_HARD \
          DB_MAXCONN DB_MAXCONN_GEVENT
    compute_resources >/dev/null 2>&1
}

fresh_conf() {
    ERP_CONF_PATH="${WORK}/erp.conf"
    printf '[options]\n' > "$ERP_CONF_PATH"
}

conf_value() { grep -E "^$1 *=" "$ERP_CONF_PATH" | head -1 | awk -F'= *' '{print $2}'; }

describe "normal — a tenant gets a bounded per-process ceiling"

it "the default per-process ceiling is set"
compute_with $(( 2 * GB )) 2
if [ -n "${COMPUTED_DB_MAXCONN:-}" ]; then pass; else
    fail "compute_resources produced no db_maxconn"
fi

it "it is far below Odoo's unbounded default of 64"
assert_lt "$COMPUTED_DB_MAXCONN" 64

it "the gevent worker gets its OWN ceiling"
# Without this key it inherits db_maxconn and the websocket bus is strangled.
if [ -n "${COMPUTED_DB_MAXCONN_GEVENT:-}" ]; then pass; else
    fail "compute_resources produced no db_maxconn_gevent"
fi

it "the gevent ceiling is higher than a plain worker's"
# gevent serves many concurrent greenlets on sub-millisecond cursors.
assert_gt "$COMPUTED_DB_MAXCONN_GEVENT" "$COMPUTED_DB_MAXCONN"

it "both land in erp.conf"
fresh_conf
compute_with $(( 2 * GB )) 2
apply_resources >/dev/null 2>&1
assert_equals "$(conf_value db_maxconn)" "$COMPUTED_DB_MAXCONN"

it "the gevent key lands too"
assert_equals "$(conf_value db_maxconn_gevent)" "$COMPUTED_DB_MAXCONN_GEVENT"

it "the ceiling does not change with container size"
# It bounds per-process concurrency, which does not scale with RAM; the worker
# COUNT is what scales.
compute_with $(( 32 * GB )) 16
big="$COMPUTED_DB_MAXCONN"
compute_with $(( 512 * MB )) 1
assert_equals "$COMPUTED_DB_MAXCONN" "$big"

describe "override — a tenant that genuinely needs more"

it "DB_MAXCONN is honoured"
FAKE_RAM_BYTES=$(( 2 * GB )); FAKE_CPU_COUNT=2
get_ram_bytes() { echo "$FAKE_RAM_BYTES"; }
get_cpu_count() { echo "$FAKE_CPU_COUNT"; }
unset WORKERS MAX_CRON_THREADS LIMIT_MEMORY_SOFT LIMIT_MEMORY_HARD DB_MAXCONN_GEVENT
DB_MAXCONN=24 compute_resources >/dev/null 2>&1
assert_equals "$COMPUTED_DB_MAXCONN" "24"

it "DB_MAXCONN_GEVENT is honoured independently"
unset DB_MAXCONN
DB_MAXCONN_GEVENT=20 compute_resources >/dev/null 2>&1
assert_equals "$COMPUTED_DB_MAXCONN_GEVENT" "20"

it "the override is documented as an env var, not as conf.db_maxconn"
# generate_config writes conf.* keys BEFORE apply_resources, and apply_resources
# skips a key it finds — so conf.db_maxconn would silently shadow the computed
# value and leave two sources of truth for one ceiling.
assert_contains "$(cat "$TENANT_COMPOSE")" 'DB_MAXCONN: ${DB_MAXCONN:-}'

it "the tenant compose does NOT set conf.db_maxconn"
if ! grep -qE '^\s*conf\.db_maxconn' "$TENANT_COMPOSE"; then pass; else
    fail "conf.db_maxconn in the compose environment block shadows the entrypoint default"
fi

describe "failure — an explicit conf.db_maxconn must win, not be duplicated"

it "an operator-set value is left alone"
fresh_conf
printf 'db_maxconn = 32\n' >> "$ERP_CONF_PATH"
compute_with $(( 2 * GB )) 2
apply_resources >/dev/null 2>&1
assert_equals "$(conf_value db_maxconn)" "32"

it "and it is not duplicated"
assert_equals "$(grep -cE '^db_maxconn *=' "$ERP_CONF_PATH")" "1"

it "setting only the gevent key does not suppress the per-process one"
# The guard greps '^db_maxconn *=' anchored on '=': a bare '^db_maxconn' would
# also match db_maxconn_gevent and skip the ceiling that matters most.
fresh_conf
printf 'db_maxconn_gevent = 30\n' >> "$ERP_CONF_PATH"
compute_with $(( 2 * GB )) 2
apply_resources >/dev/null 2>&1
if [ -n "$(conf_value db_maxconn)" ]; then pass; else
    fail "db_maxconn was skipped because the grep matched db_maxconn_gevent"
fi

describe "boundary — the cross-file invariant with the pooler"

pgb() { grep -E "^$1 *=" "$PGB_INI" | head -1 | awk -F'= *' '{print $2}' | tr -d ' '; }

it "the per-process ceiling leaves the pooler room to queue rather than error"
# Odoo raises PoolError only when a SINGLE process needs more than db_maxconn
# concurrent cursors. A prefork HTTP worker handles one request at a time and
# Odoo's own threaded-mode formula assumes ~2 cursors per thread, so the ceiling
# must stay comfortably above 2.
compute_with $(( 2 * GB )) 2
assert_ge "$COMPUTED_DB_MAXCONN" 4

it "one tenant's whole worst case stays inside PostgreSQL's budget"
# (workers + cron) x db_maxconn + gevent ceiling, x2 for the readonly pool,
# must not exceed what the cluster can serve one tenant even pathologically.
procs=$(( COMPUTED_WORKERS + COMPUTED_MAX_CRON_THREADS ))
worst=$(( (procs * COMPUTED_DB_MAXCONN + COMPUTED_DB_MAXCONN_GEVENT) * 2 ))
assert_lt "$worst" "$(pgb max_client_conn)"

it "the cron watchdog is not disabled, so a wedged cron releases its slot"
# conf.limit_time_real_cron = 0 becomes None in server.py and disables the
# watchdog outright: a wedged cron worker holds its tenant-DB session AND its
# permanent LISTEN session on `postgres` forever.
cron_limit=$(grep -oE 'conf\.limit_time_real_cron: \$\{LIMIT_TIME_REAL_CRON:-[0-9-]+\}' "$TENANT_COMPOSE" \
             | grep -oE '[0-9-]+\}$' | tr -d '}')
if [ -n "$cron_limit" ] && [ "$cron_limit" != "0" ]; then pass; else
    fail "limit_time_real_cron default is '${cron_limit:-unset}' — 0 disables the watchdog"
fi

describe "idempotency"

it "applying twice leaves one line each"
fresh_conf
compute_with $(( 2 * GB )) 2
apply_resources >/dev/null 2>&1
apply_resources >/dev/null 2>&1
assert_equals "$(grep -cE '^db_maxconn *=' "$ERP_CONF_PATH")" "1"

it "and the gevent key too"
assert_equals "$(grep -cE '^db_maxconn_gevent *=' "$ERP_CONF_PATH")" "1"

finish
