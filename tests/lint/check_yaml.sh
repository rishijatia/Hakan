#!/bin/bash
# check_yaml.sh — verify all *.yaml / *.yml files parse cleanly.
# Uses Python's PyYAML rather than yamllint to avoid external deps.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

FILES=()
if [ $# -gt 0 ]; then
    FILES=("$@")
else
    while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.yaml' '*.yml')
fi

# Also include fly.toml? No — TOML is a different parser. Keep this YAML-only.

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "  (no YAML files to check)"
    exit 0
fi

PYTHON=$(command -v python3 || command -v python)
if [ -z "$PYTHON" ]; then
    echo "✗ python3 not available — cannot validate YAML" >&2
    exit 2
fi

FAILED=0
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    if "$PYTHON" -c "import yaml,sys; yaml.safe_load(open('$f'))" 2>/tmp/yaml_err; then
        echo "  ✓ $f"
    else
        echo "  ✗ $f" >&2
        sed 's/^/      /' /tmp/yaml_err >&2
        FAILED=$((FAILED+1))
    fi
done
rm -f /tmp/yaml_err

if [ "$FAILED" -gt 0 ]; then
    echo "✗ $FAILED YAML file(s) failed parsing" >&2
    exit 1
fi
echo "✓ YAML clean (${#FILES[@]} file(s))"
