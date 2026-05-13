#!/bin/bash
# run_all.sh — run every static-lint check.
#
# Usage:
#   tests/lint/run_all.sh                    # check the whole repo
#   tests/lint/run_all.sh --staged           # only files staged for commit
#   tests/lint/run_all.sh path1 path2 ...    # check specific paths
#
# Used by:
#   - Local devs: bare invocation
#   - .githooks/pre-commit: with --staged
#   - CI (future): bare invocation
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1
HERE="$(dirname "${BASH_SOURCE[0]}")"

# Read a command's output into an array — bash 3.2-compatible (macOS-friendly).
read_into_array() {
    local _line
    eval "$1=()"
    while IFS= read -r _line; do
        eval "$1+=(\"\$_line\")"
    done
}

# Determine file list.
ALL_FILES=()
if [ "${1:-}" = "--staged" ]; then
    shift
    read_into_array ALL_FILES < <(git diff --cached --name-only --diff-filter=ACMR)
elif [ $# -gt 0 ]; then
    ALL_FILES=("$@")
else
    read_into_array ALL_FILES < <(git ls-files)
fi

# Partition by file type.
SHELL_FILES=()
YAML_FILES=()
SKILL_FILES=()
if [ "${#ALL_FILES[@]}" -gt 0 ]; then
    for f in "${ALL_FILES[@]}"; do
        case "$f" in
            *.sh)                            SHELL_FILES+=("$f") ;;
            *.yaml|*.yml)                    YAML_FILES+=("$f") ;;
            skills/custom/*/SKILL.md)        SKILL_FILES+=("$f") ;;
        esac
    done
fi

OVERALL=0

if [ "${#SHELL_FILES[@]}" -gt 0 ]; then
    echo "→ shellcheck (${#SHELL_FILES[@]} file(s))"
    bash "$HERE/check_shell.sh" "${SHELL_FILES[@]}" || OVERALL=1
fi

if [ "${#YAML_FILES[@]}" -gt 0 ]; then
    echo "→ yaml-parse (${#YAML_FILES[@]} file(s))"
    bash "$HERE/check_yaml.sh" "${YAML_FILES[@]}" || OVERALL=1
fi

if [ "${#SKILL_FILES[@]}" -gt 0 ]; then
    echo "→ SKILL.md frontmatter (${#SKILL_FILES[@]} file(s))"
    bash "$HERE/check_skills.sh" "${SKILL_FILES[@]}" || OVERALL=1
fi

if [ "$OVERALL" -ne 0 ]; then
    echo
    echo "✗ Static checks failed. Fix the issues above, or use 'git commit --no-verify' to bypass (not recommended)." >&2
    exit 1
fi

echo
echo "✓ All static checks passed."
