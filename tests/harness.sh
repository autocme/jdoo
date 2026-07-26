#!/usr/bin/env bash
# Test harness for entrypoint.sh.
#
# entrypoint.sh is a single script whose main() boots a container, so it cannot
# be sourced wholesale. The harness extracts one function at a time by its
# literal `name() {` ... `^}` boundary and evaluates only that, together with
# the logging helpers it calls. External tools (psql, openssl, gosu, docker) are
# replaced by fakes injected ahead of the real ones on PATH, so the function
# under test runs its OWN code against scripted responses — nothing here is a
# reimplementation of the logic being verified.

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${HARNESS_DIR}/../entrypoint.sh"
FAKE_BIN="$(mktemp -d)"
export PATH="${FAKE_BIN}:${PATH}"

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

# Print the source of one shell function, from `name() {` to the first line
# that is exactly `}`. Fails loudly if the boundary is not found, so a rename
# in entrypoint.sh breaks the tests instead of silently skipping them.
extract_function() {
    local name="$1"
    local body
    body=$(awk -v fn="$name" '
        $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}$/ { exit }
    ' "$ENTRYPOINT")
    if [ -z "$body" ]; then
        echo "HARNESS ERROR: function '${name}' not found in ${ENTRYPOINT}" >&2
        exit 2
    fi
    if ! printf '%s' "$body" | tail -n1 | grep -q '^}$'; then
        echo "HARNESS ERROR: function '${name}' has no closing brace" >&2
        exit 2
    fi
    printf '%s\n' "$body"
}

# Load the given functions plus the logging helpers they all call.
load_functions() {
    local name
    for name in set_state log_info log_warn log_error "$@"; do
        eval "$(extract_function "$name")"
    done
}

# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------

# Create a fake executable on PATH. The body is arbitrary shell.
fake_bin() {
    local name="$1"; shift
    printf '#!/usr/bin/env bash\n%s\n' "$*" > "${FAKE_BIN}/${name}"
    chmod +x "${FAKE_BIN}/${name}"
}

# Remove a fake so the real tool (or its absence) applies again.
unfake_bin() {
    rm -f "${FAKE_BIN}/$1"
}

# psql that succeeds and prints $1 for every query.
fake_psql_returning() {
    fake_bin psql "printf '%s\n' \"$1\"; exit 0"
}

# psql that always fails, as if the server were unreachable.
fake_psql_unreachable() {
    fake_bin psql "echo 'psql: could not connect to server' >&2; exit 2"
}

# psql that fails the first N invocations, then succeeds — a PG that is still
# starting. The counter lives in a file because each call is a new process.
fake_psql_flaky() {
    local failures="$1" then_return="${2:-1}"
    local counter="${FAKE_BIN}/.psql_calls"
    : > "$counter"
    fake_bin psql "
        counter='${counter}'
        printf 'x' >> \"\$counter\"
        calls=\$(wc -c < \"\$counter\" | tr -d ' ')
        if [ \"\$calls\" -le ${failures} ]; then
            echo 'psql: server starting up' >&2
            exit 2
        fi
        printf '%s\n' '${then_return}'
        exit 0"
}

psql_call_count() {
    local counter="${FAKE_BIN}/.psql_calls"
    [ -f "$counter" ] && wc -c < "$counter" | tr -d ' ' || echo 0
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

it() {
    CURRENT_TEST="$1"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
}

fail() {
    TESTS_FAILED=$(( TESTS_FAILED + 1 ))
    printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$CURRENT_TEST" "$1"
}

pass() {
    printf '  \033[32mok\033[0m   %s\n' "$CURRENT_TEST"
}

assert_equals() {
    if [ "$1" = "$2" ]; then pass; else
        fail "expected '${2}', got '${1}'"
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) pass ;;
        *) fail "expected output to contain '${2}'; got: ${1}" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "expected output NOT to contain '${2}'; got: ${1}" ;;
        *) pass ;;
    esac
}

assert_ge() {
    if [ "$1" -ge "$2" ] 2>/dev/null; then pass; else
        fail "expected ${1} >= ${2}"
    fi
}

assert_gt() {
    if [ "$1" -gt "$2" ] 2>/dev/null; then pass; else
        fail "expected ${1} > ${2}"
    fi
}

assert_lt() {
    if [ "$1" -lt "$2" ] 2>/dev/null; then pass; else
        fail "expected ${1} < ${2}"
    fi
}

assert_success() {
    if [ "$1" -eq 0 ]; then pass; else fail "expected exit 0, got ${1}"; fi
}

assert_failure() {
    if [ "$1" -ne 0 ]; then pass; else fail "expected non-zero exit, got 0"; fi
}

describe() { printf '\n\033[1m%s\033[0m\n' "$1"; }

finish() {
    printf '\n%d test(s), %d failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
    rm -rf "$FAKE_BIN"
    [ "$TESTS_FAILED" -eq 0 ] || exit 1
}
