#!/bin/sh
# Hook: PreToolUse (Bash)
# Blocks iterative fix commits when 3+ fixes target the same scope
# within 2 hours without evidence of doc/spec research.
#
# Detects: git commit with fix(scope) when fix(scope) already appears 2+ times recently
# Override: include [doc-verified] in the commit message
#
# Input: JSON on stdin with { "tool_input": { "command": "..." } }

INPUT=$(cat)

# Extract the full command value using python for reliable JSON parsing
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Only check git commit commands
echo "$COMMAND" | grep -qE 'git\s+commit' || exit 0

# Allow if commit message contains [doc-verified]
echo "$COMMAND" | grep -q '\[doc-verified\]' && exit 0

# Extract scope from conventional commit: fix(scope): ...
SCOPE=$(echo "$COMMAND" | grep -oE 'fix\([a-z_-]+\)' | head -1 | sed 's/fix(//;s/)//')
[ -z "$SCOPE" ] && exit 0

# Count recent fix commits with the same scope (last 2 hours)
RECENT_FIXES=$(git log --oneline --since='2 hours ago' --grep="fix($SCOPE)" 2>/dev/null | wc -l | tr -d ' ')

if [ "$RECENT_FIXES" -ge 2 ]; then
  echo ""
  echo "BLOCKED: $((RECENT_FIXES + 1)) fix($SCOPE) commits in 2 hours."
  echo ""
  echo "This looks like iterative guessing. Before committing another fix:"
  echo "  1. Read the relevant spec/docs (WebFetch, context7, hex.info)"
  echo "  2. Understand WHY the previous fixes didn't work"
  echo "  3. Add [doc-verified] to your commit message to confirm you did"
  echo ""
  echo "Recent fix($SCOPE) commits:"
  git log --oneline --since='2 hours ago' --grep="fix($SCOPE)" 2>/dev/null
  echo ""
  exit 2
fi

exit 0
