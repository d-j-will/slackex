#!/bin/sh
# Hook: PreToolUse (Bash)
# Blocks `caddy reload` in favour of `docker restart caddy`.
#
# Caddy's reload compares the new Caddyfile to its running config. If the file
# hasn't changed it reports "config is unchanged" and retains stale cached DNS
# for upstreams that were recreated with new IPs — returning 502s until the
# cache expires. A full `docker restart caddy` forces a cold start with fresh
# DNS resolution and is always safe.
#
# Input: JSON on stdin with { "tool_input": { "command": "..." } }

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | sed 's/"command":"//;s/"$//')

if echo "$COMMAND" | grep -qE 'caddy\s+reload'; then
  echo "BLOCKED: \`caddy reload\` is not allowed."
  echo "Use \`docker restart caddy\` instead."
  echo ""
  echo "Reason: caddy reload retains stale DNS for recreated upstreams when the"
  echo "Caddyfile hasn't changed, causing 502s until the cache expires."
  echo "docker restart caddy forces a cold start with fresh DNS resolution."
  exit 2
fi

exit 0
