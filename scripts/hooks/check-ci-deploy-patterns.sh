#!/bin/sh
# Hook: PreToolUse (Write/Edit)
# Checks ci-deploy.yml for common SSH heredoc mistakes.
#
# Input: JSON on stdin with tool_input containing file_path and content/new_string.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path":"[^"]*"' | head -1 | sed 's/"file_path":"//;s/"$//')

# Only check CI deploy workflow
case "$FILE_PATH" in
  *ci-deploy*) ;;
  *) exit 0 ;;
esac

CONTENT=$(echo "$INPUT" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"$//')
if [ -z "$CONTENT" ]; then
  CONTENT=$(echo "$INPUT" | grep -o '"new_string":"[^"]*"' | head -1 | sed 's/"new_string":"//;s/"$//')
fi

WARNINGS=""

# Check for heredoc terminators that might break YAML block scalars
if echo "$CONTENT" | grep -qE "<<"; then
  WARNINGS="${WARNINGS}\n- Heredoc inside YAML block scalar detected. Use printf instead to avoid YAML parse errors."
fi

if [ -n "$WARNINGS" ]; then
  echo "CI DEPLOY WARNING:${WARNINGS}"
  echo ""
  echo "Review SSH heredoc rules in CLAUDE.md Deployment Discipline section."
  exit 0
fi

exit 0
