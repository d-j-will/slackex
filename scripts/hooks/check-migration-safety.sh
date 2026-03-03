#!/bin/sh
# Hook: PreToolUse (Write/Edit)
# Checks migration files for deploy-unsafe patterns.
#
# Input: JSON on stdin with { "tool_input": { "file_path": "...", "content": "..." } }
# For Edit: { "tool_input": { "file_path": "...", "new_string": "..." } }

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path":"[^"]*"' | head -1 | sed 's/"file_path":"//;s/"$//')

# Only check migration files
case "$FILE_PATH" in
  */migrations/*.exs) ;;
  *) exit 0 ;;
esac

# Extract the content being written (Write tool uses "content", Edit uses "new_string")
CONTENT=$(echo "$INPUT" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"$//')
if [ -z "$CONTENT" ]; then
  CONTENT=$(echo "$INPUT" | grep -o '"new_string":"[^"]*"' | head -1 | sed 's/"new_string":"//;s/"$//')
fi

WARNINGS=""

# Check for NOT NULL without default
if echo "$CONTENT" | grep -qiE 'null:\s*false' && ! echo "$CONTENT" | grep -qiE 'default:'; then
  WARNINGS="${WARNINGS}\n- NOT NULL column without default detected. Add a default or make nullable first (expand phase)."
fi

# Check for drop column
if echo "$CONTENT" | grep -qiE 'remove\s+:'; then
  WARNINGS="${WARNINGS}\n- Column removal detected. Ensure no running code references this column (contract phase only)."
fi

# Check for rename
if echo "$CONTENT" | grep -qiE 'rename\s+table|rename\s+:'; then
  WARNINGS="${WARNINGS}\n- Rename detected. Use expand/contract pattern: add new, migrate data, drop old."
fi

# Check for modify/alter column type
if echo "$CONTENT" | grep -qiE 'modify\s+:.*,\s*:'; then
  WARNINGS="${WARNINGS}\n- Column type change detected. Use expand/contract: add new column, backfill, drop old."
fi

if [ -n "$WARNINGS" ]; then
  echo "MIGRATION SAFETY WARNING:${WARNINGS}"
  echo ""
  echo "Review the Migration Discipline section in CLAUDE.md before proceeding."
  # Exit 0 (warn, don't block) — migrations may be intentional contract-phase changes
  exit 0
fi

exit 0
