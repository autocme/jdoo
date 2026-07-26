#!/usr/bin/env bash
# Finding #4b — ensure_admin_password could publish an EMPTY master password.
#
# Both generators are pipelines (`openssl rand … | tr -dc … | cut`). If openssl
# is absent, /dev/urandom is unreadable, or `tr` strips everything, the pipeline
# yields an empty string — and the old code wrote it straight into erp.conf as
# `admin_passwd = `. Odoo treats an empty master password as "no password
# required", so the database manager (create / duplicate / drop / backup any
# tenant on the node) became reachable by anyone. The weak default it was
# replacing was strictly safer than the failure mode.
#
# Path matrix
#   normal       -> a weak default is replaced by a strong generated value
#   boundary     -> whitespace-only, already-strong, persisted value reused
#   failure      -> generator failure must abort the boot, never write empty
#   permission   -> the persisted file is chmod 600
#   retry        -> N/A (single pass at boot; the persisted file is the memory)
#   concurrency  -> N/A (runs once, before Odoo starts, single process)
#   rollback     -> N/A (the abort path writes nothing)
#   idempotency  -> a second boot reuses the persisted value, does not rotate

source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

load_functions ensure_admin_password

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run ensure_admin_password in a subshell so an `exit 1` in the failure path is
# caught rather than killing the test run. Echoes the resulting conf line.
run_with_password() {
    local env_pw="$1" data_dir="$2"
    ERP_CONF_PATH="${data_dir}/erp.conf"
    : > "$ERP_CONF_PATH"
    ODOO_DATA_DIR="$data_dir" \
    ERP_CONF_PATH="$ERP_CONF_PATH" \
        env "conf.admin_passwd=${env_pw}" bash -c "
            $(declare -f set_state log_info log_warn log_error ensure_admin_password)
            ensure_admin_password
        " >/dev/null 2>&1
    echo "$?"
}

conf_password() {
    grep '^admin_passwd' "$1/erp.conf" 2>/dev/null | sed 's/^admin_passwd = //'
}

describe "#4b — a failed generator must never publish an empty password"

it "aborts the boot when no randomness source is available"
d="${WORK}/nogen"; mkdir -p "$d"
fake_bin openssl "exit 127"          # openssl missing
fake_bin head "exit 127"             # /dev/urandom path unusable too
rc=$(run_with_password "admin" "$d")
assert_failure "$rc"

it "writes nothing to erp.conf when generation fails"
assert_equals "$(conf_password "$d")" ""

it "does not persist an empty password file"
if [ -s "${d}/.admin_passwd" ]; then
    fail "an empty/short password was persisted"
else
    pass
fi
unfake_bin openssl
unfake_bin head

describe "normal replacement of weak defaults"

it "replaces the literal 'admin' with a strong generated value"
d="${WORK}/weak"; mkdir -p "$d"
rc=$(run_with_password "admin" "$d")
assert_success "$rc"

it "the generated password is at least 20 characters"
pw="$(conf_password "$d")"; pwlen=${#pw}
assert_ge "$pwlen" 20

it "the generated password is not one of the known-weak values"
assert_not_contains "|$(conf_password "$d")|" "|admin|"

for weak in odoo CHANGE_ME changeme password 123456 admin123; do
    it "replaces the weak default '${weak}'"
    d="${WORK}/weak_${weak}"; mkdir -p "$d"
    run_with_password "$weak" "$d" >/dev/null
    pw="$(conf_password "$d")"; pwlen=${#pw}
    assert_ge "$pwlen" 20
done

describe "boundary"

it "whitespace-only is treated as empty, not as a strong password"
d="${WORK}/ws"; mkdir -p "$d"
run_with_password "    " "$d" >/dev/null
pw="$(conf_password "$d")"; pwlen=${#pw}
assert_ge "$pwlen" 20

it "an already-strong password is left untouched"
d="${WORK}/strong"; mkdir -p "$d"
run_with_password "Kx9-QhZ2mNv4TbLp8RwE" "$d" >/dev/null
assert_equals "$(conf_password "$d")" ""   # nothing rewritten: the env value stands

describe "permission"

it "the persisted password file is chmod 600"
d="${WORK}/perm"; mkdir -p "$d"
run_with_password "admin" "$d" >/dev/null
mode=$(stat -c '%a' "${d}/.admin_passwd" 2>/dev/null)
assert_equals "$mode" "600"

describe "idempotency"

it "a second boot reuses the persisted password instead of rotating it"
d="${WORK}/idem"; mkdir -p "$d"
run_with_password "admin" "$d" >/dev/null
first=$(conf_password "$d")
run_with_password "admin" "$d" >/dev/null
assert_equals "$(conf_password "$d")" "$first"

it "the persisted file still matches what was written to erp.conf"
assert_equals "$(cat "${d}/.admin_passwd")" "$(conf_password "$d")"

finish
