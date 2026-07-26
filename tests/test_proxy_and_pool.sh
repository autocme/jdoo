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

finish
