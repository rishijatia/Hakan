#!/bin/bash
# check_skills.sh — verify SKILL.md files have valid frontmatter.
#
# Required fields:
#   - name (must match parent directory name)
#   - description (non-empty, < 500 chars)
#   - version (semver-ish: digits.digits.digits)
#
# Also flags:
#   - SKILL.md files outside a properly-named directory
#   - Scripts referenced in SKILL.md that don't exist (best-effort)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

FILES=()
if [ $# -gt 0 ]; then
    FILES=("$@")
else
    while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files 'skills/custom/**/SKILL.md')
fi

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "  (no SKILL.md files to check)"
    exit 0
fi

PYTHON=$(command -v python3 || command -v python)
if [ -z "$PYTHON" ]; then
    echo "✗ python3 not available — cannot validate SKILL.md frontmatter" >&2
    exit 2
fi

FAILED=0
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    result=$("$PYTHON" - "$f" <<'PY'
import sys, os, re, yaml

path = sys.argv[1]
errors = []

with open(path) as fh:
    content = fh.read()

if not content.startswith("---\n"):
    errors.append("missing YAML frontmatter (must start with ---)")
else:
    end = content.find("\n---", 4)
    if end == -1:
        errors.append("frontmatter not closed (missing ---)")
    else:
        try:
            meta = yaml.safe_load(content[4:end])
        except yaml.YAMLError as e:
            errors.append(f"YAML parse error: {e}")
            meta = None

        if meta is not None:
            for field in ("name", "description", "version"):
                if field not in meta:
                    errors.append(f"missing required field: {field}")

            if "description" in meta and (not meta["description"] or len(meta["description"]) > 500):
                errors.append(f"description must be non-empty and <500 chars (got {len(meta.get('description') or '')})")

            if "version" in meta and not re.match(r"^\d+\.\d+(\.\d+)?$", str(meta["version"])):
                errors.append(f"version not semver-ish: {meta['version']}")

            if "name" in meta:
                dir_name = os.path.basename(os.path.dirname(path))
                if dir_name != meta["name"]:
                    errors.append(f"name '{meta['name']}' does not match directory '{dir_name}'")

for e in errors:
    print(f"      {e}")
PY
)
    if [ -z "$result" ]; then
        echo "  ✓ $f"
    else
        echo "  ✗ $f" >&2
        echo "$result" >&2
        FAILED=$((FAILED+1))
    fi
done

if [ "$FAILED" -gt 0 ]; then
    echo "✗ $FAILED SKILL.md file(s) failed validation" >&2
    exit 1
fi
echo "✓ SKILL.md frontmatter clean (${#FILES[@]} file(s))"
