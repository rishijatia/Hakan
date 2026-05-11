#!/bin/bash
# hermes-health-check.sh — Hermes Agent health monitor
# Reports errors, gateway status, session stats, and disk usage.
# Exit code 0 = healthy, 1 = issues found, 2 = critical.

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LOG_DIR="$HERMES_HOME/logs"
SESSION_DIR="$HERMES_HOME/sessions"
SKILL_DIR="$HERMES_HOME/skills"
CONFIG_FILE="$HERMES_HOME/config.yaml"
ENV_FILE="$HERMES_HOME/.env"
REPORT=""
ISSUES=0
CRITICAL=0

# ─── Helpers ────────────────────────────────────────────────────────
add_section() { REPORT+="\n📋 $1\n"; }
add_ok()      { REPORT+="  ✅ $1\n"; }
add_warn()    { REPORT+="  ⚠️  $1\n"; ((ISSUES++)); }
add_crit()    { REPORT+="  🔴 $1\n"; ((ISSUES++)); ((CRITICAL++)); }

# ─── 1. Config & Env ────────────────────────────────────────────────
add_section "Configuration"
if [[ -f "$CONFIG_FILE" ]]; then
    add_ok "config.yaml exists ($(wc -c < "$CONFIG_FILE") bytes)"
else
    add_crit "config.yaml missing at $CONFIG_FILE"
fi

if [[ -f "$ENV_FILE" ]]; then
    # Check key env vars exist (don't print values)
    for var in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY; do
        if grep -q "^${var}=" "$ENV_FILE" 2>/dev/null; then
            add_ok "$var is set"
        fi
    done
else
    add_warn ".env file missing — no API keys configured"
fi

# ─── 2. Gateway Status ──────────────────────────────────────────────
add_section "Gateway"
if command -v hermes &>/dev/null; then
    GW_STATUS=$(hermes gateway status 2>&1 || true)
    if echo "$GW_STATUS" | grep -qi "running\|active\|connected"; then
        add_ok "Gateway is running"
    elif echo "$GW_STATUS" | grep -qi "stopped\|inactive\|not running"; then
        add_warn "Gateway is NOT running"
    else
        REPORT+="  ℹ️  Gateway status unclear: $(echo "$GW_STATUS" | head -3)\n"
    fi
else
    add_crit "hermes CLI not found in PATH"
fi

# ─── 3. Log Analysis ────────────────────────────────────────────────
add_section "Recent Errors (last 24h)"
if [[ -d "$LOG_DIR" ]]; then
    LOG_FILES=$(find "$LOG_DIR" -name "*.log" -mtime -1 2>/dev/null)
    if [[ -n "$LOG_FILES" ]]; then
        ERROR_COUNT=$(grep -ci "error\|failed\|exception\|traceback" $LOG_FILES 2>/dev/null || echo 0)
        WARN_COUNT=$(grep -ci "warning\|warn" $LOG_FILES 2>/dev/null || echo 0)
        
        if [[ "$ERROR_COUNT" -gt 50 ]]; then
            add_crit "High error count: $ERROR_COUNT errors in last 24h"
        elif [[ "$ERROR_COUNT" -gt 10 ]]; then
            add_warn "Moderate errors: $ERROR_COUNT errors in last 24h"
        elif [[ "$ERROR_COUNT" -gt 0 ]]; then
            REPORT+="  ℹ️  $ERROR_COUNT errors, $WARN_COUNT warnings in last 24h\n"
        else
            add_ok "No errors in last 24h"
        fi
        
        # Show last 3 actual errors
        if [[ "$ERROR_COUNT" -gt 0 ]]; then
            REPORT+="  Recent errors:\n"
            grep -i "error\|failed\|exception" $LOG_FILES 2>/dev/null | tail -3 | while read -r line; do
                REPORT+="    → $(echo "$line" | cut -c1-120)\n"
            done
        fi
    else
        add_ok "No log files from last 24h (clean slate)"
    fi
else
    add_warn "Log directory not found at $LOG_DIR"
fi

# ─── 4. Session Health ──────────────────────────────────────────────
add_section "Sessions"
if [[ -d "$SESSION_DIR" ]]; then
    SESSION_COUNT=$(find "$SESSION_DIR" -name "*.jsonl" 2>/dev/null | wc -l)
    TOTAL_SIZE=$(du -sh "$SESSION_DIR" 2>/dev/null | cut -f1)
    REPORT+="  ℹ️  $SESSION_COUNT sessions, total size: $TOTAL_SIZE\n"
    
    # Warn if session store is huge
    SIZE_KB=$(du -sk "$SESSION_DIR" 2>/dev/null | cut -f1)
    if [[ "$SIZE_KB" -gt 1048576 ]]; then  # > 1GB
        add_warn "Session store is very large (${TOTAL_SIZE}) — consider pruning"
    fi
else
    add_warn "Session directory not found"
fi

# ─── 5. Skills ──────────────────────────────────────────────────────
add_section "Skills"
if [[ -d "$SKILL_DIR" ]]; then
    SKILL_COUNT=$(find "$SKILL_DIR" -name "SKILL.md" 2>/dev/null | wc -l)
    add_ok "$SKILL_COUNT skills installed"
    
    # Check for broken symlinks
    BROKEN=$(find "$SKILL_DIR" -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)
    if [[ "$BROKEN" -gt 0 ]]; then
        add_warn "$BROKEN broken skill symlinks"
    fi
else
    add_warn "Skills directory not found"
fi

# ─── 6. Disk Space ──────────────────────────────────────────────────
add_section "Disk Usage"
HERMES_SIZE=$(du -sh "$HERMES_HOME" 2>/dev/null | cut -f1)
REPORT+="  ℹ️  ~/.hermes total: $HERMES_SIZE\n"

DISK_PCT=$(df -h "$HERMES_HOME" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
if [[ -n "$DISK_PCT" ]]; then
    if [[ "$DISK_PCT" -gt 95 ]]; then
        add_crit "Disk usage at ${DISK_PCT}% — critically low"
    elif [[ "$DISK_PCT" -gt 85 ]]; then
        add_warn "Disk usage at ${DISK_PCT}%"
    else
        add_ok "Disk usage: ${DISK_PCT}%"
    fi
fi

# ─── 7. Credential Pools ────────────────────────────────────────────
add_section "Credentials"
AUTH_FILE="$HERMES_HOME/auth.json"
if [[ -f "$AUTH_FILE" ]]; then
    add_ok "auth.json present (credential pools configured)"
else
    REPORT+="  ℹ️  No auth.json (using .env keys only)\n"
fi

# ─── 8. Process Check ───────────────────────────────────────────────
add_section "Running Processes"
GW_PID=$(pgrep -f "hermes.*gateway" 2>/dev/null | head -1 || true)
if [[ -n "$GW_PID" ]]; then
    add_ok "Gateway process alive (PID: $GW_PID)"
fi

CRON_PID=$(pgrep -f "hermes.*cron\|hermes.*scheduler" 2>/dev/null | head -1 || true)
if [[ -n "$CRON_PID" ]]; then
    add_ok "Cron scheduler alive (PID: $CRON_PID)"
fi

# ─── Summary ─────────────────────────────────────────────────────────
REPORT="\n🏥 Hermes Health Report — $(date '+%Y-%m-%d %H:%M:%S')\n$REPORT"

if [[ "$CRITICAL" -gt 0 ]]; then
    REPORT+="\n🔴 RESULT: $CRITICAL critical issue(s), $ISSUES total — ACTION NEEDED\n"
    echo -e "$REPORT"
    exit 2
elif [[ "$ISSUES" -gt 0 ]]; then
    REPORT+="\n⚠️  RESULT: $ISSUES issue(s) found — review recommended\n"
    echo -e "$REPORT"
    exit 1
else
    REPORT+="\n✅ RESULT: All systems healthy\n"
    echo -e "$REPORT"
    exit 0
fi

