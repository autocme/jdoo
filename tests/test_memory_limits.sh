#!/usr/bin/env bash
# Finding #19 — limit_memory_hard was derived from limit_memory_soft by *1.3.
#
# The two settings measure different things: soft is compared against RSS and
# triggers a graceful worker recycle, while hard is applied with
# setrlimit(RLIMIT_AS) and caps ADDRESS SPACE. An Odoo worker's VSZ runs several
# times its RSS, so soft*1.3 produced an address-space ceiling below the
# worker's own steady-state footprint: workers died on startup and the tenant
# crash-looped while using a few hundred MB of real memory.
#
# Path matrix
#   normal       -> a normal container gets a workable ceiling
#   boundary     -> tiny (512MB) / large (32GB) / exactly-at-floor containers
#   failure      -> the pathological case that crash-looped must not recur
#   permission   -> N/A (no privilege boundary in a resource calculation)
#   retry        -> N/A (pure computation, no I/O)
#   concurrency  -> N/A (runs once, single-threaded, before Odoo starts)
#   rollback     -> N/A (writes nothing; apply_resources does that separately)
#   idempotency  -> same inputs produce the same numbers every run

source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

load_functions get_cpu_count get_ram_bytes parse_cpuset compute_resources

# Drive compute_resources with a chosen RAM/CPU by overriding the two probes,
# which are themselves covered by their own tests.
#
# The fake's variables MUST NOT be named `ram_bytes`/`cpu_count`: bash scoping
# is dynamic, and compute_resources declares `local cpu_count ram_bytes` before
# calling the probes — a same-named local shadows the outer value and the fake
# returns an empty string, which silently computes against 0MB of RAM.
compute_with() {
    FAKE_RAM_BYTES="$1"
    FAKE_CPU_COUNT="$2"
    get_ram_bytes() { echo "$FAKE_RAM_BYTES"; }
    get_cpu_count() { echo "$FAKE_CPU_COUNT"; }
    unset WORKERS MAX_CRON_THREADS LIMIT_MEMORY_SOFT LIMIT_MEMORY_HARD
    compute_resources >/dev/null 2>&1
}

MB=1048576
GB=1073741824

describe "#19 — the RLIMIT_AS ceiling must reflect address space, not RSS"

it "a 1GB container does not get a hard limit below a worker's real VSZ"
compute_with $(( 1 * GB )) 2
# The old formula: soft = 85% of 1GB / 4 procs = 217MB, hard = 283MB. An Odoo
# worker maps well over 1GB of address space before serving a single request.
assert_ge "$COMPUTED_LIMIT_MEMORY_HARD" $(( 2 * GB ))

it "a 512MB container still gets a usable ceiling"
compute_with $(( 512 * MB )) 1
assert_ge "$COMPUTED_LIMIT_MEMORY_HARD" $(( 2 * GB ))

it "the hard limit always exceeds the soft limit"
compute_with $(( 4 * GB )) 4
assert_gt "$COMPUTED_LIMIT_MEMORY_HARD" "$COMPUTED_LIMIT_MEMORY_SOFT"

it "a large container scales above the floor rather than being pinned to it"
compute_with $(( 32 * GB )) 8
assert_gt "$COMPUTED_LIMIT_MEMORY_HARD" $(( 2 * GB ))

it "the soft limit still tracks the RSS budget and stays within physical RAM"
compute_with $(( 4 * GB )) 4
assert_lt "$COMPUTED_LIMIT_MEMORY_SOFT" $(( 4 * GB ))

describe "the regression this replaces"

it "hard is no longer soft*1.3"
compute_with $(( 1 * GB )) 2
old_formula=$(( COMPUTED_LIMIT_MEMORY_SOFT * 13 / 10 ))
if [ "$COMPUTED_LIMIT_MEMORY_HARD" -gt "$old_formula" ]; then pass; else
    fail "hard (${COMPUTED_LIMIT_MEMORY_HARD}) is still at or below the old soft*1.3 (${old_formula})"
fi

describe "explicit operator overrides win"

it "LIMIT_MEMORY_HARD is honoured verbatim"
FAKE_RAM_BYTES=$(( 4 * GB )); FAKE_CPU_COUNT=4
get_ram_bytes() { echo "$FAKE_RAM_BYTES"; }
get_cpu_count() { echo "$FAKE_CPU_COUNT"; }
unset WORKERS MAX_CRON_THREADS LIMIT_MEMORY_SOFT
LIMIT_MEMORY_HARD=999999999 compute_resources >/dev/null 2>&1
assert_equals "$COMPUTED_LIMIT_MEMORY_HARD" "999999999"

it "LIMIT_MEMORY_SOFT is honoured verbatim"
unset LIMIT_MEMORY_HARD
LIMIT_MEMORY_SOFT=123456789 compute_resources >/dev/null 2>&1
assert_equals "$COMPUTED_LIMIT_MEMORY_SOFT" "123456789"

describe "idempotency"

it "two identical runs produce identical numbers"
compute_with $(( 2 * GB )) 4
first="${COMPUTED_LIMIT_MEMORY_SOFT}/${COMPUTED_LIMIT_MEMORY_HARD}/${COMPUTED_WORKERS}"
compute_with $(( 2 * GB )) 4
assert_equals "${COMPUTED_LIMIT_MEMORY_SOFT}/${COMPUTED_LIMIT_MEMORY_HARD}/${COMPUTED_WORKERS}" "$first"

describe "worker count boundaries (regression guard — unchanged behaviour)"

it "never drops below the 2-worker floor"
compute_with $(( 512 * MB )) 1
assert_ge "$COMPUTED_WORKERS" 2

it "a RAM-starved box is limited by RAM, not by CPU count"
compute_with $(( 1 * GB )) 16
assert_lt "$COMPUTED_WORKERS" 32

finish
