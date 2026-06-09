#!/bin/sh
# Render-validate every ```mermaid block under a docs root using mermaid-cli +
# a real browser. This is the RENDER TIER of the two-tier Mermaid gate (decision
# recorded in docs/engineering-principles.md, "Two-Tier Mermaid Gate"): unlike
# validate.mjs (parse + C4-boundary heuristic — the fast, blocking pre-deploy
# tier), this actually lays out each diagram, so it catches render/layout
# crashes (e.g. C4 auto-layout "reading 'x'") that parsing cannot. It runs
# ADVISORY in CI (ci-deploy.yml `mermaid-render` job): a failure is a red X but
# deliberately does not block the deploy path.
# The mermaid-cli version is pinned in scripts/mermaid/package.json under
# "config.mermaid-cli" — keep it in lockstep with "dependencies.mermaid" so both
# tiers validate the same grammar.
#
# Usage:  sh scripts/mermaid/render-check.sh [docs-root]
#
# Requirements:
#   - mmdc on PATH (npm install -g @mermaid-js/mermaid-cli), or set $MMDC.
#   - A Chrome/Chromium. Set $PUPPETEER_EXECUTABLE_PATH, or the script auto-detects
#     the runner's google-chrome / a local macOS "Google Chrome.app".
#   Install mermaid-cli WITHOUT puppeteer's chromium download (it is flaky / not
#   needed when a system browser exists):
#     PUPPETEER_SKIP_DOWNLOAD=true npm install -g @mermaid-js/mermaid-cli
#
# Exits non-zero (listing each failure) if any block fails to render.
set -eu

ROOT="${1:-docs}"
MMDC="${MMDC:-mmdc}"

# Locate a browser.
BROWSER="${PUPPETEER_EXECUTABLE_PATH:-}"
if [ -z "$BROWSER" ]; then
  for c in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/usr/bin/google-chrome" \
    "/usr/bin/google-chrome-stable" \
    "/usr/bin/chromium-browser" \
    "/usr/bin/chromium"; do
    if [ -x "$c" ]; then BROWSER="$c"; break; fi
  done
fi
if [ -z "$BROWSER" ] || [ ! -x "$BROWSER" ]; then
  echo "render-check: no Chrome/Chromium found. Install Chrome or set PUPPETEER_EXECUTABLE_PATH." >&2
  exit 2
fi

CFG="$(mktemp)"
OUTDIR="$(mktemp -d)"
ERR="$(mktemp)"
LIST="$(mktemp)"
trap 'rm -rf "$CFG" "$OUTDIR" "$ERR" "$LIST"' EXIT
printf '{"executablePath":"%s","args":["--no-sandbox","--disable-gpu","--disable-dev-shm-usage"]}\n' "$BROWSER" > "$CFG"

# File list goes through a temp file (not a for-loop over $(...), which
# word-splits on spaces; not a pipe into while, which loses the counters in a
# subshell). .md-only to match validate.mjs's discovery.
grep -rl --include='*.md' '```mermaid' "$ROOT" | sort > "$LIST" || true

status=0
total=0
while IFS= read -r f; do
  total=$((total + 1))
  if ! "$MMDC" -q -p "$CFG" -i "$f" -o "$OUTDIR/out.md" >"$ERR" 2>&1; then
    echo "RENDER FAIL: $f"
    detail="$(grep -iE 'error|reading|undefined' "$ERR" | head -2 || true)"
    [ -n "$detail" ] || detail="$(head -c 400 "$ERR")"
    printf '%s\n' "$detail" | sed 's/^/    /'
    status=1
  fi
done < "$LIST"

if [ "$status" -eq 0 ]; then
  echo "Mermaid render OK: all diagrams in $total doc(s) under $ROOT render."
fi
exit "$status"
