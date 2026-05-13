#!/bin/bash
# check_shell.sh — run shellcheck on all *.sh files (or a passed-in list).
#
# Usage:
#   check_shell.sh                  # all *.sh in repo
#   check_shell.sh file1.sh file2.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "✗ shellcheck not installed" >&2
    echo "  Install: brew install shellcheck (macOS) or apt install shellcheck (Linux)" >&2
    exit 2
fi

FILES=()
if [ $# -gt 0 ]; then
    FILES=("$@")
else
    # All shell scripts tracked in git (bash 3.2 compatible: while-read instead of mapfile)
    while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.sh')
fi

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "  (no shell scripts to check)"
    exit 0
fi

FAILED=0
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    if shellcheck -x -S warning "$f"; then
        echo "  ✓ $f"
    else
        FAILED=$((FAILED+1))
    fi
done

if [ "$FAILED" -gt 0 ]; then
    echo "✗ $FAILED shell script(s) failed shellcheck" >&2
    exit 1
fi
echo "✓ shellcheck clean (${#FILES[@]} file(s))"
