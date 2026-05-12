---
name: pr-fix-loop
description: "Fix Copilot PR review comments with Claude Code, reply on GitHub, request re-review. Repeat until clean."
version: 3.0.0
author: Hermes Agent
metadata:
  hermes:
    tags: [GitHub, PR, Copilot, Claude-Code, Code-Review]
    related_skills: [claude-code, github-pr-workflow, github-code-review]
---

# PR Fix Loop — Fix Copilot Review Comments with Claude Code

End-to-end workflow for resolving Copilot (or human) review comments on a PR using Claude Code, then closing the loop with GitHub replies and re-review requests.

## When to Use

- Copilot review lands with comments on a PR
- User says "fix the review comments", "handle copilot comments", "fix PR comments"
- PR Comment Monitor cron reports new unresolved comments

## Workflow Decision Tree

```
PR has unresolved comments?
  ├─ No → Exit: "PR is clean!"
  └─ Yes → delegate_task (primary — most reliable)
       → Subagent: fix + commit + push + reply + resolve
       → If subagent fails → Try Claude Code (claude -p in direct mode)
            → If credits exhausted → Manual fix by agent
```

delegate_task is preferred because Claude Code has credit limits and tmux/escaping issues. Claude Code is the fallback, not the primary.

## Quick Start

**Primary approach (delegate_task):**
```
1. Run: bash /opt/data/scripts/pr_fix_loop.sh rishijatia/Hakan 3
   (handles clone, GraphQL fetch, pre-check — exits if clean)
2. If unresolved > 0: delegate_task with toolsets=["terminal", "file"]
   (see references/delegate-task-prompt-template.md for prompt)
3. Verify: check unresolved count → repeat if > 0
```

**Fallback (Claude Code direct):**
```bash
# Only if delegate_task unavailable
bash /opt/data/scripts/pr_fix_loop.sh rishijatia/Hakan 3
```

**Flags:**
- `--force` — Skip the "already fixed" pre-check and always launch fixes

## Environment Setup (Critical)

The script must have correct environment for both `gh` and `claude`:
```bash
export PATH="/opt/data/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/opt/data/home"   # Credentials at ~/.claude/.credentials.json
[ -f ~/.bashrc ] && source ~/.bashrc  # For GH_TOKEN
```
Without `HOME`, Claude Code can't find stored OAuth credentials.

**GH_TOKEN scopes required:**
- `repo` — read/write PR comments, push code
- `workflow` — (optional) for CI-related operations
- `read:org` — required for `gh pr edit --add-reviewer @copilot` (Copilot re-review trigger)

## How the Script Works

### Step 1: Clone and checkout
```bash
gh repo clone REPO /tmp/pr-fix-NUM
git checkout BRANCH
```

### Step 2: Fetch unresolved threads via GraphQL
- Uses **GraphQL** (not REST) to get `reviewThreads` with `threadId` and `isResolved` status
- Only processes threads where `isResolved: false`
- Outputs both `/tmp/pr_comments_N.md` (for Claude Code) and `/tmp/pr_threads_N.json` (for thread resolution)
- Each entry includes: `threadId` (GraphQL `PRRT_...`), `commentId` (REST database ID), `body`, `author`

### Step 3: Pre-check (skip Claude Code if nothing to do)
- If 0 unresolved threads and no `--force` flag → exits early with "✅ PR is clean!"
- Saves an expensive Claude Code launch when all comments were already addressed

### Step 4: Fix with delegate_task (primary) or Claude Code (fallback)

**Primary: delegate_task** — Spawn a subagent with `toolsets=["terminal", "file"]`. The subagent reads the threads JSON, fixes code, commits, pushes, replies, resolves threads, and posts a summary. See `references/delegate-task-prompt-template.md` for the exact prompt structure.

**Fallback: Claude Code** — Only if delegate_task is unavailable. Uses `claude -p` in direct mode (no tmux). Handles fix + commit + push + reply + resolve in one prompt.

Both approaches do the same 7 steps:
1. Read comments file, check if each is already fixed
2. Fix unfixed issues in code
3. Commit + push (once)
4. Reply to each comment via REST `/replies`
5. **Resolve each thread** via GraphQL `resolveReviewThread` mutation
6. Post summary review comment
7. Print summary table

### Step 5: Final status
- Prints commit SHA, unpushed count, and unresolved thread count
- If unresolved > 0, the loop should be run again (see "Iterative Fix Loop" below)

## Key Lessons from Production Use

1. **Fix ALL comments in ONE run** — Copilot re-reviews the full diff on each push. Multiple fix cycles cause comment count to GROW, not shrink.

2. **Reply endpoint is POST /replies, not PATCH** — Copilot's comments aren't editable. Use `gh api repos/.../pulls/comments/{id}/replies` (POST), not `gh api repos/.../pulls/comments/{id}` (PATCH). Replies alone don't resolve threads — see lesson #7.

3. **Filter stale comments** — Use GraphQL `reviewThreads` query (not REST `/comments`) to get `isResolved` status and `threadId` for each thread. Only process unresolved threads.

4. **Push ONCE** — Each push triggers a new Copilot review on the entire diff. Pushing incrementally = more reviews = more comments.

5. **Pre-check before launching fixes** — Saves time when PR is already clean.

6. **Always pipe gh to cat** — `gh` uses a pager that breaks in non-interactive contexts. Append `2>&1 | cat`.

7. **Replies ≠ resolved** — REST `/replies` adds a comment but does NOT mark the thread as resolved. Must run `resolveReviewThread` GraphQL mutation with each thread's GraphQL ID (`PRRT_...`). Thread IDs come from the `reviewThreads` GraphQL query in Step 2.

8. **gh needs GH_TOKEN + git credential helper** — Source `~/.bashrc` for GH_TOKEN. Also configure: `git config --global credential.helper '!gh auth git-credential'`. Without both, `git push` fails silently.

9. **Copilot re-review via `gh pr edit --add-reviewer @copilot`** — This is the correct CLI command to trigger Copilot re-review. REST API `requested_reviewers` doesn't work (Copilot is a bot, not a collaborator). The CLI command requires `read:org` scope on the GH_TOKEN. Without it, the command returns a scope error. Copilot also re-reviews automatically on push, but `--add-reviewer` forces an immediate review.

10. **Fallback to delegate_task when Claude Code fails** — If Claude Code returns "out of extra usage" or errors, use `delegate_task` with `toolsets=["terminal", "file"]`. Pass working dir, threads JSON path, and auth instructions in context. The subagent can do everything Claude Code does.

11. **$ escaping through tmux send-keys is fragile** — Prompts with `$` characters get interpreted by bash. Solution: write prompt to a file, then `claude -p "$(cat ${PROMPT_FILE})"`. Or skip tmux entirely and use `claude -p` directly.

## PR Comment Monitor (Cron)

A companion cron job monitors PRs for new comments:
- **Cron:** `PR Comment Monitor` (every 2h, job `9b99d8719c52`)
- **Script:** `~/.hermes/scripts/pr_comment_monitor.py` (must be in `~/.hermes/scripts/` for cron)
- **Seen file:** `/opt/data/pr_monitor_seen.json` (tracks reported comment IDs)
- **Silent when no new comments** — only reports when fresh unresolved comments appear
- **Reset seen file** to re-report all comments: `rm /opt/data/pr_monitor_seen.json`

Setup: copy script to `~/.hermes/scripts/`, create cron with `no_agent: true` and `script: pr_comment_monitor.py` (relative path only).

When the monitor reports comments, run the fix loop:
```
User: "fix the copilot comments on PR #3"
Agent: loads this skill → runs pr_fix_loop.sh → reports results
```

## Multi-PR Support

For multiple PRs, run separate instances:
```bash
bash /opt/data/scripts/pr_fix_loop.sh rishijatia/Hakan 3 &
bash /opt/data/scripts/pr_fix_loop.sh rishijatia/Hakan 5 &
wait
```

Each clones to `/tmp/pr-fix-NUM` — no conflicts.

## Pitfalls

1. **Don't fix incrementally** — Fix everything in one pass, push once. Multiple cycles = more Copilot reviews = more comments.
2. **Comment replies use POST /replies** — PATCH returns "body is not editable" for Copilot comments.
3. **Always pipe gh to cat** — Pager breaks in background/scripted contexts.
4. **GH_TOKEN must be in environment** — Source bashrc or export explicitly.
5. **HOME must be set** — `export HOME=/opt/data/home` or Claude Code can't find credentials.
6. **--max-turns 30, --max-budget-usd 3** — Enough for typical fix loops. Budget cap prevents runaway costs.
7. **Replies ≠ resolved** — Must run `resolveReviewThread` GraphQL mutation to actually mark threads resolved. Without this, threads stay "outstanding" forever.
8. **`reviews -f event=COMMENT` ≠ re-review request** — It just posts a comment. Use `gh pr edit --add-reviewer @copilot` to trigger Copilot re-review (requires `read:org` token scope).
9. **delegate_task fallback needs git auth** — Subagents inherit environment but may not have bashrc sourced. Include in context: "source ~/.bashrc for GH_TOKEN, then run `git config --global credential.helper '!gh auth git-credential'` before push".
10. **$ escaping through tmux** — Prompts with `$` get interpreted by bash. Write prompt to file, use `claude -p "$(cat file)"`.
11. **Copilot re-review needs `read:org` scope** — `gh pr edit --add-reviewer @copilot` fails with scope error if token only has `repo,workflow`. Add `read:org` to GH_TOKEN.

## Iterative Fix Loop

Copilot reviews are **per-push** — each push triggers a fresh review that may find NEW issues in the same code. Expect to run the fix loop 2-4 times before the PR is clean:

```
Push 1 → Copilot finds 17 code issues
Push 2 → Copilot finds 6 doc/defensive coding issues
Push 3 → Copilot finds 3 minor doc issues
Push 4 → Copilot finds 7 more defensive patterns
Push 5 → Copilot finds 0 ✅
```

**Pattern:** Run the loop, check unresolved count, if > 0 run again. Each round gets more trivial. The conversation pattern is:
```
User: "more comments"
Agent: check unresolved count → delegate_task → verify → report
```

**Triggering Copilot re-review:** If Copilot doesn't auto-review after push, trigger manually:
```bash
gh pr edit PR-NUMBER --add-reviewer @copilot
```
This requires `read:org` scope on GH_TOKEN. If Copilot still doesn't review, it may have a cooldown — wait a few minutes and try again.
