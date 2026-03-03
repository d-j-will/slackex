#!/bin/sh
# Hook: PreToolUse (Bash)
# Blocks git commit --no-verify to prevent bypassing pre-commit hooks.
#
# Input: JSON on stdin with { "tool_input": { "command": "..." } }

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | sed 's/"command":"//;s/"$//')

if echo "$COMMAND" | grep -qE 'git\s+commit.*--no-verify'; then
  echo "BLOCKED: git commit --no-verify is not allowed. Pre-commit hooks are mandatory."
  echo "If the hook is failing, fix the underlying issue instead of bypassing it."
  exit 2
fi

exit 0
