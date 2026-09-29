#!/usr/bin/env bash
# Findings #25a and #28 — edge trust and connection-pool ceilings.
#
# #25a: nginx read the visitor address from CF-Connecting-IP unconditionally,
# and set X-Forwarded-Proto from $scheme. Both are wrong at the edge:
#   * the header is only meaningful from the tunnel hop. Anything able to reach
#     the node directly could claim any source address, which is what Odoo's
#     audit log, rate limiting, GeoIP and IP-based rules all rest on.
#   * TLS terminates upstream, so $scheme on the internal hop is "http" — Odoo
#     then emits http:// URLs and a session cookie without Secure.
#
# #28: PgBouncer had no per-database or per-user ceiling. The only bound on
# backends was per-pool times the number of tenants, so one busy tenant could
# exhaust PostgreSQL's max_connections for EVERY tenant on the node, and for
# the maintenance role needed to diagnose it.
#
# Path matrix
#   normal       -> the rendered nginx config is accepted by nginx itself
#   boundary     -> trusted vs untrusted source; header present vs absent
#   failure      -> a spoofed header from an untrusted source is not honoured
#   permission   -> N/A (no user/role boundary in a proxy config)
#   retry        -> N/A (static configuration, evaluated per request)
#   concurrency  -> the pool ceiling IS the concurrency guarantee; asserted
#   rollback     -> N/A (declarative config; rollback is a redeploy)
#   idempotency  -> rendering twice yields a byte-identical config

source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_CONF="${ROOT}/nginx.conf"
PGB_INI="${ROOT}/shared-pg-stack/pgbouncer.ini"
COMPOSE="${ROOT}/shared-pg-stack/docker-compose.yml"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Render the envsubst placeholders the deploy pipeline fills in.
render_nginx() {
    ODOO_PORT=8069 ODOO_INTERNAL_PORT=8069 GEVENT_INTERNAL_PORT=8072 \
        envsubst '${ODOO_PORT} ${ODOO_INTERNAL_PORT} ${GEVENT_INTERNAL_PORT}' \
        < "$NGINX_CONF" > "${WORK}/rendered.conf"
}

describe "#25a — the rendered config must be valid nginx, not merely plausible"

it "nginx itself accepts the rendered configuration"
render_nginx
mkdir -p "${WORK}/logs" "${WORK}/tmp"
cat > "${WORK}/full.conf" <<EOF
daemon off;
pid ${WORK}/nginx.pid;
error_log ${WORK}/logs/error.log;
events { worker_connections 1024; }
http {
    access_log off;
    client_body_temp_path ${WORK}/tmp;
    proxy_temp_path ${WORK}/tmp/proxy;
    fastcgi_temp_path ${WORK}/tmp/fastcgi;
    uwsgi_temp_path ${WORK}/tmp/uwsgi;
    scgi_temp_path ${WORK}/tmp/scgi;
$(cat "${WORK}/rendered.conf")
}
EOF
if nginx -t -c "${WORK}/full.conf" >"${WORK}/nginx_t.log" 2>&1; then
    pass
else
    fail "nginx -t rejected the config: $(tail -3 "${WORK}/nginx_t.log")"
fi

describe "#25a — the CF header is trusted only from a trusted hop"

it "a geo block classifies the peer address"
assert_contains "$(cat "$NGINX_CONF")" "geo \$from_trusted_proxy"

it "client_real_ip no longer reads the raw header directly"
# The old config mapped $http_cf_connecting_ip straight to $client_real_ip.
raw_map=$(awk '/^map \$http_cf_connecting_ip \$client_real_ip/{print}' "$NGINX_CONF")
assert_equals "$raw_map" ""

it "the header is gated through the trust classifier"
assert_contains "$(cat "$NGINX_CONF")" "map \$from_trusted_proxy \$trusted_cf_ip"

it "an untrusted source resolves the header to empty"
# In `map $from_trusted_proxy $trusted_cf_ip`, default (untrusted) must be "".
block=$(awk '/^map \$from_trusted_proxy \$trusted_cf_ip/,/^}/' "$NGINX_CONF")
assert_contains "$(echo "$block" | grep default)" '""'

it "a trusted source resolves the header to its value"
assert_contains "$block" "1       \$http_cf_connecting_ip"

it "the loopback hop is trusted"
geo_block=$(awk '/^geo \$from_trusted_proxy/,/^}/' "$NGINX_CONF")
assert_contains "$geo_block" "127.0.0.0/8"

it "the docker overlay range is trusted"
assert_contains "$geo_block" "10.0.0.0/8"

it "the default verdict is untrusted"
assert_contains "$(echo "$geo_block" | grep default)" "0"

describe "#25a — the forwarded scheme is honoured, but only from a trusted hop"

it "no proxy_set_header still hardcodes \$scheme"
leftover=$(grep -c 'X-Forwarded-Proto \$scheme' "$NGINX_CONF" || true)
assert_equals "$leftover" "0"

it "every X-Forwarded-Proto goes through the trust map"
total=$(grep -c 'X-Forwarded-Proto' "$NGINX_CONF")
gated=$(grep -c 'X-Forwarded-Proto \$client_proto' "$NGINX_CONF")
assert_equals "$gated" "$total"

it "an absent forwarded scheme falls back to the connection scheme"
proto_block=$(awk '/^map \$forwarded_proto_in \$client_proto/,/^}/' "$NGINX_CONF")
assert_contains "$proto_block" '""      $scheme'

it "the websocket location restates the gated headers"
# nginx cancels inherited proxy_set_header inside a location that sets any.
ws_block=$(awk '/location \/websocket/,/^    }/' "$NGINX_CONF")
assert_contains "$ws_block" "X-Forwarded-Proto \$client_proto"

it "the websocket location also uses the gated client IP"
assert_contains "$ws_block" "X-Real-IP \$client_real_ip"

describe "idempotency"

it "rendering twice produces byte-identical output"
render_nginx; cp "${WORK}/rendered.conf" "${WORK}/first.conf"
render_nginx
if cmp -s "${WORK}/first.conf" "${WORK}/rendered.conf"; then pass; else
    fail "envsubst is not deterministic"
fi

describe "#28 — PgBouncer must not let one tenant exhaust the cluster"

it "a per-database ceiling is configured"
assert_contains "$(cat "$PGB_INI")" "max_db_connections"

it "a per-user ceiling is configured"
assert_contains "$(cat "$PGB_INI")" "max_user_connections"

it "the per-database ceiling leaves headroom under PostgreSQL max_connections"
db_cap=$(grep -E '^max_db_connections' "$PGB_INI" | awk -F'= *' '{print $2}' | tr -d ' ')
pg_max=$(grep -oE 'max_connections=\$\{PG_MAX_CONNECTIONS:-[0-9]+\}' "$COMPOSE" \
         | grep -oE '[0-9]+$')
[ -z "$pg_max" ] && pg_max=500
assert_lt "$db_cap" "$pg_max"

it "the ceiling is at least the steady-state pool so normal load is unaffected"
pool=$(grep -E '^default_pool_size' "$PGB_INI" | awk -F'= *' '{print $2}' | tr -d ' ')
reserve=$(grep -E '^reserve_pool_size' "$PGB_INI" | awk -F'= *' '{print $2}' | tr -d ' ')
assert_ge "$db_cap" $(( pool + reserve ))

it "a single tenant can no longer reach max_connections on its own"
# The defect: one pool could grow until PG refused everyone.
if [ "$db_cap" -lt "$pg_max" ]; then pass; else
    fail "one database may still consume the whole cluster (${db_cap} >= ${pg_max})"
fi

it "session pool_mode is unchanged — this fix does not alter pooling semantics"
assert_contains "$(grep -E '^pool_mode' "$PGB_INI")" "session"

# =============================================================================
# 2026-09-28 fleet-wide login outage.
#
# Every tenant on the node lost the ability to log in at the same moment, while
# existing sessions kept working. Cause, in order:
#   1. Odoo opens sessions on the `postgres` MAINTENANCE database — two permanent
#      LISTEN sessions per tenant (server.py WorkerCron.start, bus.py
#      ImDispatch.loop) plus one per database-resolving request, because
#      conf.dbfilter being set makes service/db.py:list_dbs skip its
#      `if not dbfilter and db_name` short-circuit.
#   2. [databases] had ONE wildcard entry, so `postgres` inherited the global
#      max_db_connections (30) and was oversubscribed ~4x at 16 tenants.
#   3. auth_query ran against auth_dbname=postgres — the SAME saturated bucket.
#      Once full, PgBouncer could not authenticate ANY new client for ANY tenant.
# The fix is structural: `postgres` gets its own bounded entry, and the auth
# lookup gets a separate bucket that tenant load cannot consume.
#
# Path matrix for this block
#   normal      -> the three buckets exist with their own ceilings
#   boundary    -> the arithmetic fits inside max_connections, with the
#                  per-tenant share on `postgres` exactly equal to the cap
#   failure     -> the pidfile restart-loop and the SCRAM-pivot are unreachable
#   permission  -> the auth entry must not force a server-side role (`user=`)
#   retry       -> N/A (static configuration)
#   concurrency -> the ceilings ARE the concurrency guarantee; asserted
#   rollback    -> N/A (declarative; rollback is a recreate of pgbouncer)
#   idempotency -> N/A (no rendering step for this file)
# =============================================================================

MAX_TENANTS_PER_NODE=20   # keep in sync with the CAPACITY BUDGET header in pgbouncer.ini

pgb_global() { grep -E "^$1 *=" "$PGB_INI" | head -1 | awk -F'= *' '{print $2}' | tr -d ' '; }
pgb_db_line() { grep -E "^$1 *=" "$PGB_INI" | head -1; }
pgb_db_key() {
    # value of key $2 on the [databases] entry named $1 (e.g. pool_size=6)
    pgb_db_line "$1" | grep -oE "(^| )$2=[^ ]+" | head -1 | cut -d= -f2
}

describe "#OUTAGE — the maintenance database has its own bounded pool"

it "an explicit [databases] entry exists for postgres"
if [ -n "$(pgb_db_line postgres)" ]; then pass; else
    fail "no 'postgres = ...' entry: the maintenance DB would inherit the wildcard cap again"
fi

it "it carries its own pool_size, reserve_pool and max_db_connections"
for k in pool_size reserve_pool max_db_connections; do
    [ -n "$(pgb_db_key postgres "$k")" ] || fail "postgres entry has no $k"
done
pass

it "the wildcard entry is still present so tenant churn needs no reload"
assert_contains "$(pgb_db_line '\*')" "auth_user=pgbouncer_auth"

describe "#OUTAGE — auth_query capacity that tenant load cannot starve"

auth_dbname=$(pgb_global auth_dbname)

it "auth_dbname is set"
if [ -n "$auth_dbname" ]; then pass; else fail "auth_dbname is unset"; fi

it "auth_dbname is NOT the maintenance database"
if [ "$auth_dbname" != "postgres" ]; then pass; else
    fail "auth_query shares the postgres bucket — the exact outage condition"
fi

it "auth_dbname is NOT the admin console database"
if [ "$auth_dbname" != "pgbouncer" ]; then pass; else
    fail "PgBouncer rejects auth_dbname=pgbouncer and would refuse to start"
fi

it "a [databases] entry exists for auth_dbname"
if [ -n "$(pgb_db_line "$auth_dbname")" ]; then pass; else
    fail "auth_dbname=$auth_dbname has no [databases] entry, so it gets no bucket of its own"
fi

it "that entry targets the postgres database and has its own ceiling"
if echo "$(pgb_db_line "$auth_dbname")" | grep -q 'dbname=postgres' \
   && [ -n "$(pgb_db_key "$auth_dbname" max_db_connections)" ]; then pass; else
    fail "auth entry must set dbname=postgres and its own max_db_connections"
fi

it "that entry does NOT force a server-side role"
# `user=` would run every client of this entry AS pgbouncer_auth, letting a
# tenant call pgbouncer_auth.get_auth('<other tenant>') and read its SCRAM verifier.
if ! echo "$(pgb_db_line "$auth_dbname")" | grep -qE '(^| )user='; then pass; else
    fail "user= on the auth entry is a SCRAM-verifier pivot for any tenant"
fi

it "pgbouncer_auth can still read the console"
# It is the ONLY identity in auth_file, so removing it leaves no way to run
# SHOW POOLS during an incident — get_auth() filters out superusers.
assert_contains "$(pgb_global stats_users)" "pgbouncer_auth"

describe "#OUTAGE — the ceilings provably fit inside PostgreSQL max_connections"

tenant_cap=$(pgb_global max_db_connections)
pg_cap=$(pgb_db_key postgres max_db_connections)
pgb_pool=$(pgb_db_key postgres pool_size)
pgb_res=$(pgb_db_key postgres reserve_pool)
auth_cap=$(pgb_db_key "$auth_dbname" max_db_connections)
pg_max=$(grep -oE 'max_connections=\$\{PG_MAX_CONNECTIONS:-[0-9]+\}' "$COMPOSE" | grep -oE '[0-9]+$')
[ -z "$pg_max" ] && pg_max=500
su_res=$(grep -oE 'superuser_reserved_connections=\$\{PG_SUPERUSER_RESERVED:-[0-9]+\}' "$COMPOSE" | grep -oE '[0-9]+$')
[ -z "$su_res" ] && su_res=10

it "the whole budget fits under max_connections minus the superuser reserve"
total=$(( tenant_cap * MAX_TENANTS_PER_NODE + pg_cap + auth_cap ))
assert_lt "$total" $(( pg_max - su_res ))

it "no tenant can take another tenant's share of the maintenance database"
# pool_size is per (role, database): MAX_TENANTS x (pool + reserve) must fit the
# per-database cap, so a tenant exhausts its own share and nobody else's.
assert_ge "$pg_cap" $(( MAX_TENANTS_PER_NODE * (pgb_pool + pgb_res) ))

it "a tenant can reach its reserve before hitting its own cap"
pool=$(pgb_global default_pool_size)
reserve=$(pgb_global reserve_pool_size)
assert_ge "$tenant_cap" $(( pool + reserve ))

it "the per-role ceiling never binds before the per-database ones"
assert_ge "$(pgb_global max_user_connections)" $(( tenant_cap + pgb_pool + pgb_res ))

describe "#OUTAGE — the pidfile restart-loop cannot recur"

it "pidfile is present but EMPTY"
# PgBouncer is PID 1 in the foreground, so a pidfile buys nothing — and it lives
# in the container's writable layer, so it survives `docker restart` and every
# restart then dies with "FATAL pidfile exists, another instance running?".
# Observed on this stack: RestartCount 11062, last healthy check 54 days earlier.
if grep -qE '^pidfile *=' "$PGB_INI" && [ -z "$(pgb_global pidfile)" ]; then pass; else
    fail "pidfile must be set and empty (found: '$(pgb_global pidfile)')"
fi

it "the compose entrypoint execs pgbouncer in the foreground"
assert_contains "$(cat "$COMPOSE")" "exec pgbouncer /etc/pgbouncer/pgbouncer.ini"

describe "#OUTAGE — the accept queue survives a fleet-wide reconnect"

it "listen_backlog is raised above the 128 default"
assert_ge "$(pgb_global listen_backlog)" 512

describe "#OUTAGE — nothing may kill a permanent LISTEN session"

it "client_idle_timeout is absent or disabled"
# The two LISTEN clients per tenant are idle BY DEFINITION.
cit=$(pgb_global client_idle_timeout)
if [ -z "$cit" ] || [ "$cit" = "0" ]; then pass; else
    fail "client_idle_timeout=$cit would disconnect every tenant's cron and bus LISTEN"
fi

it "the postgres service sets no idle_session_timeout"
# A real setting only, not the comment warning against it. idle_in_transaction_
# session_timeout is a different, wanted knob — hence the leading-boundary match.
if ! grep -qE '^\s*-\s*(")?idle_session_timeout=' "$COMPOSE"; then pass; else
    fail "idle_session_timeout would terminate the permanent LISTEN backends"
fi

it "the file explains why session mode is mandatory"
# A future reader must not 'optimise' this to transaction pooling.
assert_contains "$(sed -n '1,40p' "$PGB_INI")" "LISTEN"

describe "PgBouncer does not support trailing comments"

it "every ';' comment is on its own line"
# A trailing comment becomes part of the VALUE — silent, and this file is mostly
# comments now.
bad=$(grep -nE '^[^;]*[^;[:space:]];' "$PGB_INI" | grep -vE '^\s*[0-9]+:\s*;' || true)
if [ -z "$bad" ]; then pass; else
    fail "trailing ';' comment(s): $bad"
fi

finish
