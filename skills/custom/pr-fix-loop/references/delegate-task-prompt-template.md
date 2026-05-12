# Delegate Task Prompt Template

When Claude Code is unavailable, use this prompt structure with `delegate_task`:

## Required toolsets
```
toolsets=["terminal", "file"]
```

## Goal template

```
Fix N Copilot review comments on PR #X (owner/repo, branch feat/xxx).

The N unresolved threads:

1. Comment {COMMENT_ID} / Thread {THREAD_ID}: {brief description}
2. Comment {COMMENT_ID} / Thread {THREAD_ID}: {brief description}
...

Steps:
1. Read full comment bodies via: /opt/data/bin/gh api repos/{OWNER}/{REPO}/pulls/comments/{COMMENT_ID} --jq '.body'
2. Fix the code issues in {WORKING_DIR}/{FILE_PATHS}
3. Commit and push (after: source ~/.bashrc 2>/dev/null && git config --global credential.helper '!gh auth git-credential')
4. Reply to EACH comment: /opt/data/bin/gh api repos/{OWNER}/{REPO}/pulls/comments/{COMMENT_ID}/replies -f body='Fixed ✅ — [description]'
5. Resolve EACH thread: /opt/data/bin/gh api graphql -f query='mutation($tid: ID!) { resolveReviewThread(input: {threadId: $tid}) { thread { isResolved } } }' -f tid={THREAD_ID}
6. Post summary: /opt/data/bin/gh api repos/{OWNER}/{REPO}/pulls/{PR}/reviews -f event=COMMENT -f body='All N review threads addressed and resolved. Please re-review.'

Return a summary of what was fixed and resolution status.
```

## Context template

```
PR #X on owner/repo, branch feat/xxx. Files under path/. Working directory: /tmp/pr-fix-X (already cloned on branch). gh CLI at /opt/data/bin/gh. Auth: source ~/.bashrc for GH_TOKEN, then git config --global credential.helper '!gh auth git-credential' before push.
```

## Key details

- The subagent inherits the environment but may not have bashrc sourced
- Always include the git credential helper instruction
- Pass the threads JSON file path if available: `/tmp/pr_threads_{PR}.json`
- Include all thread IDs and comment IDs in the goal — don't make the subagent fetch them
- Typical completion time: 2-5 minutes for 3-7 comments
