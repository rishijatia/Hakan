#!/bin/bash
# tests/smoke/_lib.sh — shared helpers for smoke tests.
# Source this from each test script; do not run directly.
# (shebang present so shellcheck knows the target shell)

GATEWAY_APP="${GATEWAY_APP:-hermes-gateway}"
SQUAD_APP="${SQUAD_APP:-hermes-coding-squad}"

# Colors (only if stdout is a TTY).
if [ -t 1 ]; then
    C_GREEN='\033[32m'
    C_RED='\033[31m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_GREEN=''; C_RED=''; C_DIM=''; C_RESET=''
fi

pass() {
    printf "${C_GREEN}✓${C_RESET} %s\n" "$1"
}

fail() {
    printf "${C_RED}✗${C_RESET} %s\n" "$1" >&2
    [ -n "${2:-}" ] && printf "${C_DIM}    %s${C_RESET}\n" "$2" >&2
    return 1
}

# flyssh APP "command string" — run a command on a Fly app over SSH.
# Forces bash so shell operators (|, &&, >) work properly.
flyssh() {
    local app="$1"; shift
    fly ssh console -a "$app" -C "bash -c $(printf '%q' "$*")" 2>&1
}

# Assert that the given command output contains the needle string.
#   assert_contains <output> <needle> <fail_message>
assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) return 0 ;;
        *) fail "$msg" "expected to contain: $needle"; return 1 ;;
    esac
}

# Assert that the given output does NOT contain the needle.
assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) fail "$msg" "should not contain: $needle"; return 1 ;;
        *) return 0 ;;
    esac
}
