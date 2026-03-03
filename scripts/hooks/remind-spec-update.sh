#!/usr/bin/env bash
# PostToolUse:Bash hook — injects a spec-update reminder after git commits.
#
# Claude Code passes the tool call as JSON on stdin. We extract the command
# field and check whether it was a git commit. If so, we output a reminder
# that Claude will see as a system-reminder in the next turn.
#
# JSON shape (PostToolUse):
#   { "tool_input": { "command": "git commit ..." }, "tool_response": {...} }

INPUT=$(cat)

# Extract the command field. Use Python3 (always available with Elixir installs)
# and fall back to a simple grep if unavailable.
if command -v python3 &>/dev/null; then
  COMMAND=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    pass
" 2>/dev/null)
else
  # Rough fallback: pull the command value from raw JSON
  COMMAND=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)
fi

# Only fire on git commit (not git commit --amend warnings, etc.)
if printf '%s' "$COMMAND" | grep -qE '^\s*git commit'; then
  echo "Spec update reminder: a commit was just made. Check specs/README.md and the relevant phase spec (specs/0*.md) for any [ ] checkboxes that should now be [x]. Update them and include the spec files in the same commit or a follow-up commit."
fi

exit 0
