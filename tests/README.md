# tests/

Lightweight test + hygiene scaffolding for this repo. Built in layers so each adds value without depending on the next.

## Layout

```
tests/
├── lint/            Static checks (no infra needed) — Layer 1
│   ├── check_shell.sh        shellcheck on all *.sh
│   ├── check_yaml.sh         YAML parse on all *.yaml/*.yml
│   ├── check_skills.sh       SKILL.md frontmatter validator
│   └── run_all.sh            Orchestrator (used by pre-commit + CI)
├── skills/          (future) Per-skill unit tests — Layer 2
└── smoke/           (future) Live infrastructure smoke tests — Layer 3
```

## Layer 1: Static Checks

Catches syntax-level breakage before it reaches the repo.

**Run everything against the whole repo:**
```bash
bash tests/lint/run_all.sh
```

**Just the staged files (what the pre-commit hook does):**
```bash
bash tests/lint/run_all.sh --staged
```

**Specific files:**
```bash
bash tests/lint/run_all.sh skills/custom/call-agent/scripts/call_agent.sh
```

### What's checked

| Check | Tool | Catches |
|-------|------|---------|
| Shell | `shellcheck -S warning` | quoting bugs, missing `[[`, `&&`/`||` misuse, etc. |
| YAML | Python `yaml.safe_load` | malformed YAML, tab/indent issues |
| SKILL.md | Custom validator | missing required frontmatter (name/description/version), name mismatch with directory, oversized description |

### Required tools

- `shellcheck` — `brew install shellcheck` (macOS) or `apt install shellcheck` (Linux)
- `python3` with PyYAML — already installed on most systems

## Pre-commit Hook

Enable once per clone:

```bash
git config core.hooksPath .githooks
```

After that, every `git commit` runs `tests/lint/run_all.sh --staged` and blocks the commit on failure. Bypass with `git commit --no-verify` if absolutely necessary (and explain why in the commit message).

## What's NOT covered yet

- **Skill unit tests** — would isolate each script and verify its behavior with mocked inputs.
- **Live smoke tests** — would hit deployed Fly apps to verify peer-to-peer, audit roundtrip, guardrail refusal.
- **GitHub Actions CI** — would run Layer 1 on every PR.

These are next on the roadmap.
