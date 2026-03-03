#!/bin/sh
# Hook: PreToolUse (Bash)
# Blocks bare `docker pull` in favour of `docker compose pull`.
#
# Docker Compose tracks image digests independently of the Docker daemon cache.
# A bare `docker pull` updates the daemon cache but Compose does not recognise
# the change — it silently continues running containers from the old digest.
# `docker compose pull` updates Compose's own digest record so that the next
# `docker compose up --force-recreate` actually uses the new image.
#
# Input: JSON on stdin with { "tool_input": { "command": "..." } }

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | sed 's/"command":"//;s/"$//')

# Match `docker pull` that is NOT preceded by `compose` on the same token
# i.e. block "docker pull foo" but allow "docker compose pull"
if echo "$COMMAND" | grep -qE '(^|[^a-z])docker\s+pull'; then
  # Allow if `compose` appears between `docker` and `pull`
  if echo "$COMMAND" | grep -qE 'docker\s+compose\s+pull'; then
    exit 0
  fi
  echo "BLOCKED: bare \`docker pull\` is not allowed."
  echo "Use \`docker compose pull\` instead."
  echo ""
  echo "Reason: bare docker pull updates the daemon cache but Docker Compose"
  echo "tracks digests independently — Compose will silently keep running"
  echo "containers from the old image. docker compose pull updates Compose's"
  echo "own digest so --force-recreate picks up the new image correctly."
  exit 2
fi

exit 0
