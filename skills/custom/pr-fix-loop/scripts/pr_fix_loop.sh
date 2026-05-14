#!/usr/bin/env bash
# pr_fix_loop.sh — Autonomous PR fix loop via Claude Code
#
# Usage: bash pr_fix_loop.sh <owner/repo> <pr_number> [--force]

set -uo pipefail

REPO="${1:?Usage: pr_fix_loop.sh <owner/repo> <pr_number> [--force]}"
PR="${2:?Usage: pr_fix_loop.sh <owner/repo> <pr_number> [--force]}"
FORCE="${3:-}"
GH="/opt/data/bin/gh"
CLAUDE="/opt/data/bin/claude"
WORKDIR="/tmp/pr-fix-${PR}"
COMMENTS_FILE="/tmp/pr_comments_${PR}.md"
THREADS_FILE="/tmp/pr_threads_${PR}.json"
PROMPT_FILE="/tmp/pr_prompt_${PR}.txt"

export PATH="/opt/data/bin:/usr/local/bin:/usr/bin:/bin"
export HOME=/opt/data/home
[ -f ~/.bashrc ] && source ~/.bashrc 2>/dev/null
# Ensure git can use GH_TOKEN for push
if [ -n "${GH_TOKEN:-}" ]; then
    git config --global credential.helper '!gh auth git-credential'
fi

echo "=== PR Fix Loop: ${REPO}#${PR} ==="

# ── Step 1: Clone and checkout ──────────────────────────────────────
echo "[1/4] Cloning PR #${PR}..."
rm -rf "${WORKDIR}"
${GH} repo clone "${REPO}" "${WORKDIR}" 2>&1 | cat
cd "${WORKDIR}" || exit 1

BRANCH=$(${GH} pr view "${PR}" --repo "${REPO}" --json headRefName -q '.headRefName' 2>/dev/null | cat)
echo "  Branch: ${BRANCH}"
git checkout "${BRANCH}" 2>&1 | cat

# ── Step 2: Fetch unresolved threads via GraphQL ───────────────────
echo "[2/4] Fetching review threads via GraphQL..."

OWNER="${REPO%%/*}"
REPO_NAME="${REPO#*/}"

${GH} api graphql -f query="
query {
  repository(owner: \"${OWNER}\", name: \"${REPO_NAME}\") {
    pullRequest(number: ${PR}) {
      reviewThreads(last: 100) {
        nodes {
          id
          isResolved
          comments(last: 5) {
            nodes {
              id
              databaseId
              body
              author { login }
            }
          }
        }
      }
    }
  }
}
" 2>/dev/null | python3 -c "
import json, sys

data = json.load(sys.stdin)
threads = data['data']['repository']['pullRequest']['reviewThreads']['nodes']

unresolved = []
seen = set()
for t in threads:
    if t['isResolved']:
        continue
    comments = t['comments']['nodes']
    root = comments[0]
    body = root.get('body', '')
    if 'Pull request overview' in body or 'GitHub Copilot' in body:
        continue
    key = body[:80]
    if key in seen:
        continue
    seen.add(key)
    unresolved.append({
        'threadId': t['id'],
        'commentId': root['databaseId'],
        'body': body[:200],
        'author': root['author']['login'],
        'fullBody': root['body']
    })

with open('${THREADS_FILE}', 'w') as f:
    json.dump(unresolved, f, indent=2)

with open('${COMMENTS_FILE}', 'w') as f:
    f.write('# Review Comments to Fix\n\n')
    f.write(f'Total: {len(unresolved)} unresolved threads\n\n')
    for c in unresolved:
        f.write(f'''## Thread {c[\"threadId\"]}
Comment ID: {c[\"commentId\"]}
Author: {c[\"author\"]}
{c[\"fullBody\"]}

---

''')

print(f'{len(unresolved)}')
" > /tmp/comment_count_${PR}.txt 2>&1

COMMENT_COUNT=$(cat /tmp/comment_count_${PR}.txt | tr -d '[:space:]')
COMMENT_COUNT="${COMMENT_COUNT:-0}"
echo "  ${COMMENT_COUNT} unresolved threads"

# ── Step 3: Pre-check ─────────────────────────────────────────────
if [ "${COMMENT_COUNT}" -eq 0 ] && [ "${FORCE}" != "--force" ]; then
    echo ""
    echo "✅ No unresolved threads. PR is clean!"
    exit 0
fi

# ── Step 4: Fix with Claude Code (direct, no tmux) ────────────────
echo "[3/4] Fixing with Claude Code..."
echo "  Working dir: ${WORKDIR}"

# Write prompt to file to avoid escaping issues
cat > "${PROMPT_FILE}" <<PROMPT_EOF
You are fixing review comments on a GitHub PR. Do ALL of the following:

1. Read the review comments in ${COMMENTS_FILE}
2. For each comment, check if the issue is already fixed in the current codebase. If already fixed, skip to step 5.
3. For comments NOT yet fixed: edit the files to address each comment
4. If you made changes: git add -A && git commit -m 'fix: address review comments' && git push origin ${BRANCH}
5. Reply to EVERY comment listed in the file via gh API. For each Comment ID, run:
   ${GH} api repos/${REPO}/pulls/comments/{COMMENT_ID}/replies -f body='Fixed ✅ — [brief description of what was fixed or already resolved]'
6. For EVERY thread listed in the file, RESOLVE it via GraphQL. For each Thread ID (starts with PRRT_), run:
   ${GH} api graphql -f query='mutation(\$tid: ID!) { resolveReviewThread(input: {threadId: \$tid}) { thread { isResolved } } }' -f tid={THREAD_ID}
7. Post a summary review comment noting all threads are addressed:
   ${GH} api repos/${REPO}/pulls/${PR}/reviews -f event=COMMENT -f body='All ${COMMENT_COUNT} review threads addressed and resolved. Please re-review.'

Do steps 5-7 for ALL comments/threads, even ones already fixed. After all steps, print a summary table showing: file, status (fixed/skipped/resolved).
PROMPT_EOF

# Run Claude Code directly
${CLAUDE} -p "$(cat ${PROMPT_FILE})" --allowedTools 'Read,Edit,Write,Bash' --max-turns 30 --max-budget-usd 3 2>&1 | cat

# ── Final status ───────────────────────────────────────────────────
echo ""
echo "[4/4] Final status:"
FINAL_COMMIT=$(git log --oneline -1 2>/dev/null || echo "none")
FINAL_PUSHED=$(git log --oneline "origin/${BRANCH}..HEAD" 2>/dev/null | wc -l)
echo "  Commit: ${FINAL_COMMIT}"
echo "  Unpushed: ${FINAL_PUSHED}"
echo ""

# Verify thread resolution
UNRESOLVED_AFTER=$(${GH} api graphql -f query="
query { repository(owner: \"${OWNER}\", name: \"${REPO_NAME}\") {
    pullRequest(number: ${PR}) { reviewThreads(last: 100) { nodes { isResolved } } }
}}" --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length' 2>/dev/null || echo "?")
echo "  Unresolved threads remaining: ${UNRESOLVED_AFTER}"
echo ""
echo "=== Script complete ==="
