#!/usr/bin/env bash
# The shared PostgreSQL service had no forensics, no fd headroom and a planner
# tuned for spinning disks (fixed 2026-09-29).
#
# When every tenant on jaah-w1 lost logins at once, there was NO trail: logging
# was entirely at defaults (logging_collector off, log_min_duration_statement -1,
# log_connections off), so the reconstruction had to come from container restart
# counts and live pool counters. Alongside that:
#   * random_page_cost was 4.0 — a spinning-disk number on NVMe, which makes the
#     planner prefer sequential scans over the narrow index lookups Odoo does most
#   * no ulimits anywhere, so both containers inherited a 1024 SOFT nofile limit;
#     for PgBouncer that caps the whole node at ~500 clients and fails as
#     "accept(): Too many open files" with no hint that fds are the cause
#   * /dev/shm defaulted to 64MB, so parallel plans fail with "could not resize
#     shared memory segment" on a box that otherwise looks fine
#
# This file parses the compose text, so it needs no Docker. `docker compose
# config` is additionally run when Docker is present.
#
# Path matrix
#   normal      -> every setting is present with the intended default
#   boundary    -> the planner/fd values are asserted as thresholds, not equality
#   failure     -> a hardcoded (non-overridable) value fails the loop assertion
#   permission  -> N/A (no role boundary in a compose file)
#   retry       -> N/A (declarative)
#   concurrency -> nofile/shm are the concurrency guarantees; asserted
#   rollback    -> N/A (rollback is git checkout + recreate)
#   idempotency -> N/A (no rendering step)

source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPG="${ROOT}/shared-pg-stack"
COMPOSE="${SPG}/docker-compose.yml"
ENV_EXAMPLE="${SPG}/.env.example"

# The value of a `-c key=value` postgres command argument, default included.
pg_arg() { grep -oE "^[[:space:]]*-[[:space:]]*\"?$1=[^\"]*" "$COMPOSE" | head -1 | cut -d= -f2-; }
pg_arg_default() { pg_arg "$1" | grep -oE ':-[^}]+' | cut -c3-; }
# The block of the compose file belonging to one service.
service_block() { awk -v s="  $1:" '$0 == s {inside=1; next} inside && /^  [a-z]/ {exit} inside {print}' "$COMPOSE"; }

describe "forensics — there must be a trail next time"

for key in log_connections log_disconnections log_min_duration_statement \
           log_lock_waits log_statement log_temp_files log_line_prefix \
           log_autovacuum_min_duration track_activity_query_size; do
    it "postgres sets ${key}"
    if [ -n "$(pg_arg "$key")" ]; then pass; else fail "${key} is not configured"; fi
done

it "log_line_prefix names the role and the database"
# The image default is "%m [%p] " — a line cannot be attributed to a tenant.
prefix="$(pg_arg log_line_prefix)"
if echo "$prefix" | grep -q '%u' && echo "$prefix" | grep -q '%d'; then pass; else
    fail "log_line_prefix must contain %u and %d (got: ${prefix})"
fi

it "log_statement is not 'all'"
# ddl catches tenant provisioning and module installs; all is the flood.
if [ "$(pg_arg_default log_statement)" != "all" ]; then pass; else
    fail "log_statement=all will flood the node"
fi

it "logging_collector stays off so Docker captures stderr"
# A collector would bury the log inside PGDATA where nothing rotates it.
if [ "$(pg_arg logging_collector)" = "off" ]; then pass; else
    fail "logging_collector must be off (got: $(pg_arg logging_collector))"
fi

it "the postgres logs are rotated"
# Turning logging on without rotation is a disk-full outage.
assert_contains "$(service_block postgres)" "max-size"

it "the pgbouncer logs are rotated"
assert_contains "$(service_block pgbouncer)" "max-size"

describe "planner — these nodes are SSD"

it "random_page_cost is an SSD value"
rpc="$(pg_arg_default random_page_cost)"
awk -v v="${rpc:-4}" 'BEGIN { exit !(v <= 1.5) }' && pass || \
    fail "random_page_cost=${rpc} is a spinning-disk default"

it "effective_io_concurrency is raised"
assert_ge "$(pg_arg_default effective_io_concurrency)" 100

describe "file descriptors and shared memory"

it "postgres declares a nofile limit"
assert_contains "$(service_block postgres)" "nofile"

it "pgbouncer declares a nofile limit"
# At the inherited 1024 soft limit, max_client_conn=2000 is a fiction.
assert_contains "$(service_block pgbouncer)" "nofile"

it "both nofile limits are well above the inherited 1024 soft limit"
for svc in postgres pgbouncer; do
    soft=$(service_block "$svc" | grep -oE 'soft: \$\{[A-Z_]+:-[0-9]+\}' | grep -oE '[0-9]+' | tail -1)
    if [ "${soft:-0}" -lt 16384 ]; then
        fail "${svc} nofile soft is ${soft:-unset}, still near the inherited 1024"
        break
    fi
done
[ "${soft:-0}" -ge 16384 ] && pass

it "postgres declares shm_size for parallel query"
assert_contains "$(service_block postgres)" "shm_size"

describe "leak bounds — without touching the permanent LISTEN sessions"

it "an idle-in-transaction session is bounded"
if [ -n "$(pg_arg idle_in_transaction_session_timeout)" ]; then pass; else
    fail "an idle-in-transaction session is an unbounded leak"
fi

it "idle_session_timeout is NOT set"
# 🔴 It would terminate the two permanent LISTEN sessions every tenant holds on
# the `postgres` database (server.py WorkerCron.start, bus.py ImDispatch.loop).
if ! grep -qE '^[[:space:]]*-[[:space:]]*"?idle_session_timeout=' "$COMPOSE"; then pass; else
    fail "idle_session_timeout would kill every tenant's cron and bus LISTEN"
fi

it "dead peers are reaped on the postgres side too"
for k in tcp_keepalives_idle tcp_keepalives_interval tcp_keepalives_count; do
    [ -n "$(pg_arg "$k")" ] || fail "${k} is not configured"
done
pass

describe "every tuning value must stay overridable per node"

it "no postgres -c argument hardcodes a value"
# The whole point of PG_* is that a 100GB node and a 4GB node get different
# numbers. A hardcoded value silently pins every node to the test-node default.
# password_encryption, the log ROUTING keys and the log FORMAT are policy, not
# sizing: a per-node override of them buys nothing and would only let one node
# stop being attributable (log_line_prefix) or stop being captured by Docker.
POLICY='password_encryption|logging_collector|log_destination|log_line_prefix'
bad=""
while read -r line; do
    val="${line#*=}"
    key="${line%%=*}"
    echo "$key" | grep -qE "$POLICY" && continue
    echo "$val" | grep -q '\${' || bad="${bad} ${key}"
done < <(grep -oE '^[[:space:]]*-[[:space:]]*"?[a-z_]+=[^"]*' "$COMPOSE" \
         | sed -E 's/^[[:space:]]*-[[:space:]]*"?//' | grep '=')
if [ -z "$bad" ]; then pass; else fail "hardcoded (not overridable):${bad}"; fi

it "the new keys are documented in .env.example"
for k in PG_SUPERUSER_RESERVED PG_RANDOM_PAGE_COST PG_LOG_MIN_DURATION \
         PG_NOFILE PGBOUNCER_NOFILE PG_SHM_SIZE; do
    grep -q "$k" "$ENV_EXAMPLE" || fail "${k} is undocumented in .env.example"
done
pass

it "the capacity budget warns that PG_MAX_CONNECTIONS is not a free knob"
# Lowering it, or raising the pool ceilings without it, reproduces the outage.
assert_contains "$(cat "$ENV_EXAMPLE")" "CAPACITY BUDGET"

describe "the file is still valid compose"

it "docker compose accepts it"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if (cd "$SPG" && PG_SUPERPASS=x AUTH_PASS=x docker compose config -q >/dev/null 2>&1); then
        pass
    else
        fail "docker compose config rejected shared-pg-stack/docker-compose.yml"
    fi
else
    pass  # docker absent: the text assertions above still ran
fi

finish
