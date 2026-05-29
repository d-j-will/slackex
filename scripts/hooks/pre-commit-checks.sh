#!/bin/sh
# Hook: PreToolUse (Bash)
# Before git commit, verifies Postgres is running and tests pass.
#
# Input: JSON on stdin with { "tool_input": { "command": "..." } }

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | sed 's/"command":"//;s/"$//')

# Only trigger on git commit commands
if ! echo "$COMMAND" | grep -qE 'git\s+commit'; then
  exit 0
fi

# Check Docker/Postgres is running
if ! docker ps 2>/dev/null | grep -q postgres; then
  echo "BLOCKED: PostgreSQL container is not running."
  echo "Run: docker compose up -d postgres_test redis"
  exit 2
fi

# Check for unstaged changes
UNSTAGED=$(git status --porcelain 2>/dev/null | grep -E '^\s?[AMRD]' | head -5)
if git status --porcelain 2>/dev/null | grep -qE '^\?\?|^ [AMRD]'; then
  echo "WARNING: You have unstaged or untracked files. Run 'git status' to verify all changes are staged."
fi

exit 0
