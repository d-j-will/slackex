#!/bin/sh
# Hook: PreToolUse (Write/Edit)
# Warns when creating or modifying PubSub listener modules to ensure
# integration tests verify the full producer → consumer wiring.
#
# Input: JSON on stdin with { "tool_input": { "file_path": "...", ... } }

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path":"[^"]*"' | head -1 | sed 's/"file_path":"//;s/"$//')

# Only check listener files
case "$FILE_PATH" in
  *_listener.ex) ;;
  *) exit 0 ;;
esac

# Extract content (Write uses "content", Edit uses "new_string")
CONTENT=$(echo "$INPUT" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"$//')
if [ -z "$CONTENT" ]; then
  CONTENT=$(echo "$INPUT" | grep -o '"new_string":"[^"]*"' | head -1 | sed 's/"new_string":"//;s/"$//')
fi

# Check if it subscribes to a PubSub topic
if echo "$CONTENT" | grep -qiE 'PubSub\.subscribe|subscribe'; then
  echo "LISTENER WIRING REMINDER:"
  echo "- This listener subscribes to a PubSub topic."
  echo "- Ensure there is an integration test that verifies the full producer -> consumer path."
  echo "- Do NOT only test the handler by faking the upstream event — that proves the handler works, not the wiring."
  echo ""
  echo "See: docs/rca/2026-03-06-pipeline-events-bridge-missing.md"
  echo "See: CLAUDE.md 'Spec-Driven Acceptance Tests'"
  exit 0
fi

exit 0
