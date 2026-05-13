#!/bin/bash
# tests/skills/_lib.sh — assertions + helpers for skill unit tests.
# Source from each test; do not run directly.

# Counters (the orchestrator reads these from the test's exit code).
TESTS_PASS=0
TESTS_FAIL=0

if [ -t 1 ]; then
    C_GREEN='\033[32m'
    C_RED='\033[31m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_GREEN=''; C_RED=''; C_DIM=''; C_RESET=''
fi

# t_pass <test_name>
t_pass() {
    printf "  ${C_GREEN}✓${C_RESET} %s\n" "$1"
    TESTS_PASS=$((TESTS_PASS+1))
}

# t_fail <test_name> [details]
t_fail() {
    printf "  ${C_RED}✗${C_RESET} %s\n" "$1" >&2
    [ -n "${2:-}" ] && printf "${C_DIM}      %s${C_RESET}\n" "$2" >&2
    TESTS_FAIL=$((TESTS_FAIL+1))
}

# Assert two values equal.
#   assert_eq <test_name> <actual> <expected>
assert_eq() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        t_pass "$name"
    else
        t_fail "$name" "expected: $expected   got: $actual"
    fi
}

# Assert substring is found.
#   assert_contains <test_name> <haystack> <needle>
assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) t_pass "$name" ;;
        *) t_fail "$name" "expected to contain: $needle" ;;
    esac
}

# Assert substring NOT found.
assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) t_fail "$name" "should NOT contain: $needle" ;;
        *) t_pass "$name" ;;
    esac
}

# Assert a command exits with a given status. Captures stdout+stderr.
#   assert_exit_status <test_name> <expected_status> <command...>
assert_exit_status() {
    local name="$1" expected="$2"; shift 2
    local out status
    out=$("$@" 2>&1) && status=0 || status=$?
    if [ "$status" -eq "$expected" ]; then
        t_pass "$name"
    else
        t_fail "$name" "expected exit $expected, got $status. output: ${out:0:200}"
    fi
}

# Make a temp dir for a test. Caller's responsibility to clean up
# (or let the OS handle it — these live in /tmp and are small).
# We deliberately don't trap here because $() runs in a subshell and
# the trap would fire before the caller can use the directory.
mktest() {
    mktemp -d -t hakan-skilltest-XXXXXX
}

# End-of-test summary; sets exit code to fail count.
t_summary() {
    local total=$((TESTS_PASS + TESTS_FAIL))
    printf "  ${C_DIM}── %d passed, %d failed (of %d) ──${C_RESET}\n" \
        "$TESTS_PASS" "$TESTS_FAIL" "$total"
    return "$TESTS_FAIL"
}
