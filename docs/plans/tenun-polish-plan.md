# Tenun Polish & Vision Plan

**Date:** 2026-03-20
**Status:** Draft

## Priority Order

### Phase 1: Dogfood Immediately (1 hour)

**6. Wire up incoming webhooks to CI**
- Create a `#deploys` channel on prod
- Create a webhook via IEx pointing to `#deploys`
- Add webhook URL to GitHub Actions secrets
- Update `ci-deploy.yml` to POST deploy notifications to Tenun alongside Discord
- First message Tenun sends to itself — proof the platform works
- Dependency: none, everything is already built

### Phase 2: Fix What's Broken (1-2 days)

**3. Chat input disappears when scrolling (mobile)**
- Root cause: compose area not properly pinned in the flex layout on mobile browsers/PWA
- Investigate `position: sticky` vs `fixed` for the compose area
- Test across mobile Chrome, Safari, PWA standalone mode
- The safe area inset fix (v0.5.90) was step one — this needs a deeper look at the scroll container structure

**1. DM summarization**
- Channel summarization already exists via `Summarizer` + `SummaryModal`
- Extend to DMs: add summarize button to DM conversation header
- Wire through same `Summarizer.summarize/1` pipeline
- Mostly UI wiring — the backend should work as-is since it operates on messages

### Phase 3: Visual Identity (3-5 days)

**2 + 4. UI alignment + design identity**
- This is a design sprint, not a bug fix. Tenun needs its own look.
- Start with a mood board / design exploration (invoke `/frontend-design` or similar)
- Key directions to explore:
  - The "weaving" metaphor — subtle textile/thread visual language
  - Dark factory aesthetic — muted, precise, things happening in the background
  - Agent-native feel — not just chat bubbles, but a platform where work flows
- Deliverables:
  - New color palette (evolve beyond the current daisyUI defaults)
  - Typography choices
  - Component redesign: sidebar, message bubbles, compose area, headers
  - Mobile-first — the PWA is the primary experience now
  - Fix alignment issues as part of the redesign (not separately)
- Consider: custom logo/icon to replace the placeholder "T"

### Phase 4: Agent Visibility (2-3 days)

**5. Make agents first-class in the UX**
- This builds on Phase 3's visual identity
- Ideas to explore:
  - Agent activity indicator — "Dark factory is working..." subtle animation
  - Spec status in channels — when a spec is being processed, show progress
  - Bot messages styled distinctly (not just a badge — different bubble shape, color, or layout)
  - Webhook activity feed — recent incoming webhook deliveries visible somewhere
  - Agent avatar system — generated avatars for bot users, not just initials
- This is what separates Tenun from "just another chat app"

### Phase 5: MCP Server (1-2 weeks)

**7. Expose Tenun to agents via MCP**
- Layer 1 #2 from the vision roadmap
- Channels, messages, metrics exposed via MCP protocol
- JSON-RPC over SSE, API token auth, channel-scoped access
- Enables: Claude Desktop / Claude Code reading channels, posting as bot, querying data
- This is the input pipeline for the dark factory — conversations become specs
- Prerequisite for the full vision: idea on phone → agent refines → factory implements

## Dependencies

```
Phase 1 (webhooks CI) — standalone, do first
  ↓
Phase 2 (fix broken stuff) — standalone, do before redesign
  ↓
Phase 3 (visual identity) — requires Phase 2 fixes done so redesign starts from clean state
  ↓
Phase 4 (agent visibility) — builds on Phase 3 design language
  ↓
Phase 5 (MCP server) — independent technically, but better after UX is solid
```

## Principles

1. **Dogfood first** — every improvement should be tested by using Tenun daily
2. **Mobile-first** — the PWA is the primary experience
3. **Identity before features** — Tenun needs to feel like Tenun, not Slack-with-a-different-name
4. **Agents are users** — design for human AND agent participants equally
