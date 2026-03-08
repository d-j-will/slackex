# Slackex Vision Roadmap

**Date:** 2026-03-08
**Status:** Discovery / Strategic direction

---

## The Vision

Slackex evolves from a chat app into an **agent-native development platform**. Ideas are captured conversationally (on mobile, over huddles, in channels), refined into specs by AI agents, implemented by a dark factory, verified by unseen scenarios, and monitored by observability infrastructure that agents can query directly.

The full loop:

```
Capture (phone/huddle/chat)
  → Refine (AI agent via MCP turns conversation into spec)
    → Implement (dark factory, consensus-based)
      → Verify (unseen scenarios, independent confirmation)
        → Monitor (OTEL/Prometheus, agent-queryable)
          → Review (huddle/pair programming)
            → Status back to Slackex channel
```

---

## Discovery Documents

| # | Document | Path |
|---|----------|------|
| 1 | Observability & OTEL | `docs/research/observability-otel-discovery-2026-03-08.md` |
| 2 | MCP Product Discovery Workflow | `docs/research/mcp-product-discovery-workflow-discovery-2026-03-08.md` |
| 3 | Tauri Desktop & Mobile App | `docs/research/tauri-desktop-mobile-app-discovery-2026-03-08.md` |
| 4 | Huddles & Voice Calls | `docs/research/huddles-voice-calls-discovery-2026-03-08.md` |
| 5 | Dark Factory | `docs/research/dark-factory-spec-driven-development-discovery-2026-03-08.md` |
| 6 | Remote Pair Programming | `docs/research/remote-pair-programming-discovery-2026-03-08.md` |

---

## Dependency Graph

```
                    ┌──────────────┐
                    │ Observability│
                    │ (OTEL)       │
                    └──────┬───────┘
                           │ enables agent debugging
                           ▼
                    ┌──────────────┐
                    │ MCP Server   │──────────────────────┐
                    │              │                       │
                    └──────┬───────┘                       │
                           │ enables agent access          │
                           ▼                               ▼
                    ┌──────────────┐              ┌──────────────┐
                    │ Tauri App    │              │ Dark Factory │
                    │              │              │              │
                    └──────┬───────┘              └──────────────┘
                           │ enables persistent        ▲
                           │ audio + native UX         │ dogfood on
                           ▼                           │ Slackex itself
                    ┌──────────────┐                   │
                    │ Huddles      │───────────────────┘
                    │              │
                    └──────┬───────┘
                           │ enables collaborative review
                           ▼
                    ┌──────────────┐
                    │ Pair         │
                    │ Programming  │
                    └──────────────┘
```

---

## Recommended Order

### Layer 1: Infrastructure (do first — makes everything else better)

#### 1. Observability (OTEL + Prometheus + Grafana)
- **Why first:** Pays for itself on day one. Every current and future incident is cheaper. Prerequisite for agents to be effective at anything.
- **Effort:** Medium. Mostly configuration — add OTEL deps, deploy Prometheus/Grafana/Tempo as Docker containers.
- **LXC impact:** ~350-500 MB additional RAM.
- **Immediate value:** BEAM process health, Ecto query tracing, Oban job metrics, supervisor restart alerts. Would have prevented multi-deploy incident cycles.

#### 2. MCP Server
- **Why second:** The foundation everything plugs into. Once Slackex exposes channels/messages/metrics via MCP, any agent can connect.
- **Effort:** Medium. JSON-RPC over SSE, API token auth, channel-scoped access.
- **LXC impact:** Negligible — runs inside existing Phoenix app.
- **Immediate value:** Connect Claude Desktop / Claude Code to Slackex. Read channels, post as bot, query observability data. Also the input pipeline for the dark factory (conversations → specs).

#### 3. Tauri Desktop App
- **Why third:** Thin shell around existing LiveView. Day-one value: tray icon, native notifications, no more hunting for the right browser tab.
- **Effort:** Low-medium for MVP. Webview loading remote URL, system tray, notifications.
- **LXC impact:** Zero — runs on user's machine.
- **Immediate value:** Always-on presence, native notifications. Prerequisite for good huddle UX later.

### Layer 2: Features (build on the infrastructure)

#### 4. Huddles (Voice Calls)
- **Why fourth:** Depends on Tauri for persistent audio across navigation. Cloudflare Realtime means no infra work on your LXC.
- **Effort:** Medium-high. Cloudflare API integration, huddle GenServer, JS WebRTC hook, huddle bar UI.
- **LXC impact:** Zero media processing — Cloudflare handles it. Just signaling and state management.
- **Value:** Real-time voice for reviewing work, discussing features, team collaboration.

#### 5. Dark Factory
- **Why fifth:** By now you have observability (agents can see), MCP (agents can interact), and a real codebase to dogfood on. This is where it all comes together.
- **Effort:** High. Pipeline orchestration, agent integration, two-tier testing, internal consensus loops. But can be adopted incrementally.
- **Value:** The end goal — spec-driven autonomous development, verified by unseen scenarios, with full observability.
- **Start small:** Pick one well-scoped feature. Write the spec manually. Run it through. Compare results. Iterate the factory.

#### 6. Pair Programming
- **Why last:** Lowest urgency for solo/small team. Becomes valuable when more people join or when reviewing dark factory output collaboratively.
- **Effort:** Low (shared tmux) to high (full remote control).
- **Start with:** tmux + xterm.js for terminal pairing, screen share from huddles for visual review.

---

## Principles

1. **Dogfood everything.** Slackex monitors itself (observability → alerts → Slackex channel). Slackex features are built by the dark factory. Ideas are captured in Slackex channels via MCP.

2. **Infrastructure before features.** Observability and MCP make every subsequent feature easier to build, debug, and verify.

3. **Agents are first-class users.** MCP isn't an afterthought — it's how agents interact with Slackex. Observability isn't just dashboards — it's data agents query to debug and verify.

4. **External services for heavy lifting.** Cloudflare Realtime for media, DeepInfra for AI, Grafana Cloud as a fallback. The LXC handles application logic; heavy infrastructure runs elsewhere.

5. **Incremental adoption.** Every item has a useful MVP that delivers value before the full vision is realised. Don't wait for the dark factory to benefit from observability.

---

## The North Star

You're walking your dogs, you have an idea, you type it into Slackex on your phone. Your AI agent reads it via MCP, refines it into a spec, and kicks off the dark factory. The factory implements it, its internal adversarial loops reach consensus, unseen scenarios verify the result. Observability confirms no regressions. A notification pops up on your Tauri app: "Feature X implemented and verified. Ready for review." You join a huddle to discuss it with a collaborator, share your screen to walk through the changes. You approve. It deploys.

You never opened an IDE.
