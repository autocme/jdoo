#!/usr/bin/env bash
# The tenant's admin password was set on a best-effort basis.
#
# By the time this block runs, odoo-bin has already created the database with
# Odoo's default admin/admin. Every failure to replace that was a `log_warn`
# and the boot continued — so an undecodable hash, a psql error, a missing
# admin row, or a failed ORM call each published a tenant to the internet with
# the default credentials, reporting success. This is the same fail-open class
# as #4b, one layer further in: #4b was the DATABASE MANAGER password, this is
# the tenant's own administrator.
#
# It is also where the master-side fix for #4a lands: the control plane now
# refuses to emit an empty partner_password_hash, and this end refuses to serve
# a database whose password it could not set. Neither side alone is sufficient.
#
# Path matrix
#   normal       -> a valid hash is applied and verified by row count
#   boundary     -> hash containing $ and a single quote; no credentials given
#   failure      -> undecodable base64, psql error, zero rows updated
#   permission   -> N/A (runs as the container's own DB role, no privilege step)
#   retry        -> N/A (one attempt at init; a failed boot is the retry signal)
#   concurrency  -> N/A (single process, before Odoo accepts any connection)
#   rollback     -> N/A (refusing to serve IS the compensation; nothing partial)
#   idempotency  -> re-applying the same hash is stable

source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

load_functions _sql_quote

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The password block is inside initialize_database, so drive it through a
# reduced copy of exactly those lines rather than re-implementing them: the
# awk extraction pulls the real source out of entrypoint.sh.
ENTRY="$(dirname "${BASH_SOURCE[0]}")/../entrypoint.sh"

extract_password_block() {
    awk '/# Set admin password/,/^    fi$/' "$ENTRY"
}

run_password_block() {
    local hash_value="$1"
    ( set +e
      INIT_PASSWORD_HASH="$hash_value"
      init_password_hash="${INIT_PASSWORD_HASH:-}"
      init_password="admin"
      db_password=pw db_host=h db_port=5432 db_user=u init_db=qadb
      STATE_FILE="${WORK}/state"
      eval "$(declare -f set_state log_info log_warn log_error _sql_quote)"
      run_block() { eval "$(extract_password_block)"; }
      run_block
      echo "rc=$?" > "${WORK}/rc"
    ) > "${WORK}/out" 2>&1
    grep -o '[0-9]*' "${WORK}/rc" 2>/dev/null | head -1
}

state_now() { cat "${WORK}/state" 2>/dev/null || echo ""; }

VALID_HASH='$pbkdf2-sha512$25000$abcdefghij$QAQAQAQA'
VALID_B64="$(printf '%s' "$VALID_HASH" | base64 -w0)"

describe "the SQL literal is built safely"

it "a hash containing a dollar sign survives unchanged"
assert_equals "$(_sql_quote 'a$b')" "'a\$b'"

it "a single quote is doubled, not left to terminate the literal"
assert_equals "$(_sql_quote "a'b")" "'a''b'"

it "an empty value is still a valid literal"
assert_equals "$(_sql_quote '')" "''"

it "a realistic pbkdf2 hash round-trips into one literal"
quoted=$(_sql_quote "$VALID_HASH")
assert_contains "$quoted" 'pbkdf2-sha512'

describe "failure — the boot must stop rather than serve admin/admin"

it "an undecodable hash aborts instead of warning"
fake_bin base64 "exit 1"
rc=$(run_password_block "!!!not-base64!!!")
unfake_bin base64
assert_equals "$rc" "1"

it "an undecodable hash records the failure state"
assert_contains "$(state_now)" "ADMIN_PASSWORD_FAILED"

it "the log names the actual consequence, not a vague warning"
assert_contains "$(cat "${WORK}/out")" "admin/admin"

it "a psql error aborts"
rm -f "${WORK}/state"
fake_bin psql "echo 'ERROR:  relation \"res_users\" does not exist' >&2; exit 1"
rc=$(run_password_block "$VALID_B64")
assert_equals "$rc" "1"

it "a psql error records the failure state"
assert_contains "$(state_now)" "ADMIN_PASSWORD_FAILED"

it "an UPDATE that matched no row aborts — a no-op is not a success"
rm -f "${WORK}/state"
fake_bin psql "echo 'UPDATE 0'; exit 0"
rc=$(run_password_block "$VALID_B64")
assert_equals "$rc" "1"

it "the zero-row case is reported as a failure state too"
assert_contains "$(state_now)" "ADMIN_PASSWORD_FAILED"

describe "normal"

it "a valid hash applied to exactly one row succeeds"
rm -f "${WORK}/state"
fake_bin psql "echo 'UPDATE 1'; exit 0"
rc=$(run_password_block "$VALID_B64")
assert_equals "$rc" "0"

it "success leaves no failure state behind"
assert_equals "$(state_now)" ""

it "success is reported in the log"
assert_contains "$(cat "${WORK}/out")" "Password hash set"

describe "boundary"

it "no hash and the default password leaves the block a no-op"
rm -f "${WORK}/state"
fake_bin psql "echo 'UPDATE 1'; exit 0"
rc=$(run_password_block "")
assert_equals "$rc" "0"

it "a hash containing a quote is applied rather than breaking the statement"
rm -f "${WORK}/state"
tricky=$(printf '%s' "\$pbkdf2\$a'b\$c" | base64 -w0)
fake_bin psql "echo 'UPDATE 1'; exit 0"
rc=$(run_password_block "$tricky")
assert_equals "$rc" "0"

describe "idempotency"

it "applying the same hash twice is stable"
fake_bin psql "echo 'UPDATE 1'; exit 0"
first=$(run_password_block "$VALID_B64")
second=$(run_password_block "$VALID_B64")
assert_equals "$second" "$first"

finish
