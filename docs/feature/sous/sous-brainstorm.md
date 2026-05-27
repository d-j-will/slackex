# Sous — brainstorm & future-directions breakdown

_2026-05-27. Source: the Sous design handoff (`/tmp/sous-design/tenun/project/design_handoff_sous/`). This is analysis + recommended slicing, **not** a commitment to build. It reads the README against **our actual codebase** to separate "already have it" from "genuinely new", then proposes where to start._

## TL;DR

Sous is **not a re-skin** (Loom was). It's a product thesis layered on top of the chat app we already have:

> Every unit of work (change, decision, incident, customer report, idea, hire) is a first-class object on one **work-item event stream**. Each role (CEO/CTO/EM/PO/CSM/Architect/Staff) reads the *same* stream through a **role-shaped lens** that right-sizes help and hides what isn't their altitude.

The chat substrate (Sous "Phase 1") is **~90% already built and now Loom-themed**. The novel, hard, valuable part is the **work-item event stream + per-viewer facets/attention + the role surfaces** (Sous Phases 3–5). That's where all the risk and all the differentiation live.

**Recommended first slice:** a thin vertical tracer-bullet through the event stream — `WorkItem` + `WorkItemEvent` (append-only) + the `/decide` composer command + the **In Service** board rendering one viewer's facet/attention. One surface, one viewer, real data flowing chat → work item → board. Everything else composes against that spine.

---

## 1. What we already have (Sous Phase 1 ≈ done)

Mapping the README's "Phase 1 — Chat substrate" to the current app:

| README Phase 1 item | Status in our codebase |
|---|---|
| Workspaces · channels · DMs · threads | ✅ `Chat` context, `ChatLive.Index`, `ThreadPanelComponent` |
| Markdown (bold/italic/strike/code/links/headings/quote/lists/code blocks) | ✅ `:markdown_rendering` (Earmark + scrubber) |
| Reactions, mentions, unread | ✅ `:reactions`; `@user` mentions; unread counts |
| Real-time presence (PubSub) | ✅ Phoenix.Presence + PubSub |
| Channel browser, ⌘K palette w/ semantic search | ✅ `:quick_switcher`, `:message_search` (pgvector; **StubClient in prod**) |
| The Loom (⌘J channel summarisation) | ✅ `:channel_summarization` + the Loom-styled summary drawer |

**Implication:** don't rebuild Phase 1. The chat surface *is* Sous's substrate. Sous-specific chat additions that are genuinely new: the **"On the Loom" ambient strip** (live trunk SHA/CI/freeze), **decision cards** (`/decide`), **customer-voice cards** (`&customer` unfurl), **oncall handoff cards**, and the **echo-dedup hint**. These are additive chat features, not a rebuild.

## 2. The genuinely new substance (Sous Phases 3–5)

This is the product. Three layers, each depends on the one before:

**(a) Work-item event stream** — append-only `WorkItemEvent` log; `WorkItem` projection. Every state transition (Order → Mise → Pass → Walked) and facet change is an event. Projections feed every surface. This is standard event-sourcing-lite; Elixir/Ecto/PubSub is a *good* fit. Low technical risk, high design risk (getting the event/atom shape right).

**(b) Viewer-aware facets + attention** — per-(viewer, work_item): a `facet_text` line + `attention ∈ {act, watch, know, hidden}`. **This is the heart and the hard part.** Open questions: who writes the initial facet (AI? lead?), when (eager on event vs lazy on open), and cost/latency of generating 7 facets × N work items via Claude.

**(c) Role surfaces** — 6 lens views (Pass, Reduction, Stack, Expo, Floor) + the **In Service** board (⌘L). Each is a LiveView projecting the stream through the active viewer's filter/grouping. The **Facet Drawer** (same atom through all 6 prisms side-by-side) is the "demo moment".

## 3. Hard constraints from OUR infra (the design under-weights these)

The README assumes a generous AI budget. Our prod reality (from `CLAUDE.md` + memory):
- **No GPU / EXLA CPU OOMs the 20GB LXC** → local Bumblebee embeddings run as `StubClient` in prod. **Semantic search is degraded in prod today.** Sous leans on semantic features (echo dedup, ⌘K) — so Sous should use **API-based embeddings** (Voyage/Anthropic) not local Bumblebee, OR accept text-only search in prod.
- **Facet generation is API-based** (`claude-haiku-4-5` via Anthropic API) → sidesteps the GPU constraint (no local inference), but introduces **per-facet API cost + latency**. 7 viewers × every work item × regenerate-on-change could get expensive fast. The facet-cadence decision (eager vs lazy, cache invalidation) is a real cost lever, not a detail.
- **Resilience rules** (`CLAUDE.md`): any new supervised process / AI pipeline must be `restart: :temporary`, errors loud not swallowed, blast-radius contained. Facet generation must be a non-essential, isolated, retry-safe Oban pipeline — not inline in the request path.

## 4. The visual delta from Loom (cheap, mostly done)

Same warm-charcoal/gold palette and fonts as Loom — so the Loom CSS layer is **80% reusable**. Two deltas:
- **No italics anywhere** — Sous enforces `em { font-style: normal }` globally; Instrument Serif **upright** for mastheads via `.is-serif`. Loom uses serif *italic* for AI moments/titles. So a "Sous" visual mode = Loom tokens + upright-serif + italic-off. (Our Appearance panel already has a serif-AI toggle — the upright variant is a small extension.)
- New surface-specific styling (the board columns, facet drawer, pass masthead, etc.) — net-new but on the existing token system.

## 5. Future directions — slicing options

Ordered by leverage. Each is a shippable vertical slice.

**Option A — Event-stream tracer bullet (RECOMMENDED first).**
`WorkItem` + `WorkItemEvent` schema (append-only) · `/decide` composer command creating a `:decision` work item from a thread · the **In Service** board (⌘L) rendering the 4 columns for ONE hard-coded viewer with static facet/attention. Proves the chat→work-item→board spine end-to-end. ~1 focused build. Everything else composes on this.

**Option B — Viewer lens + facets (the demo moment).**
Add the `viewer` model + "Reading as" switcher + AI facet generation (Oban pipeline, API, cached) + the **Facet Drawer** (same atom × 6 prisms). This is the differentiator but depends on A. Highest product risk (facet quality/cost).

**Option C — One role surface, deep.**
Pick the surface that best demos the thesis — likely **The Pass** (leadership read; visually striking, mostly read-only projection) or **The Expo** (customer-voice-rides-to-ship, the strongest narrative). Build it fully against the stream. Good for a portfolio centrepiece.

**Option D — Customer voice spine.**
`VoiceItem` → `Theme` → `Order` → `WorkItem` with `voice_ids` carried through to ship. The "why did we build this? — here's the original customer quote" payoff. Self-contained, strong story, less dependent on the 7-lens machinery.

**Anti-recommendation:** do NOT attempt all 8 surfaces × 7 viewers as one effort. That's months and most of it is projection plumbing once A+B exist.

## 6. Recommended path

1. **Decide the framing first:** is Sous a *new product* (new app/workspace) or an *evolution of Tenun* (these surfaces added behind flags to the existing app)? The README says "Sous, for now" (provisional brand). Cheapest + most demoable: **build it into the existing app behind a `:sous` (or per-surface) flag**, reusing the Loom chat substrate. Confirm this before any schema.
2. **Slice A** (event-stream tracer bullet) — proves the spine, low risk.
3. **Slice B** (viewer + facets + drawer) — the demo moment, once A is solid.
4. Then **one surface deep** (C) for the portfolio centrepiece.
5. Voice spine (D) and the remaining surfaces as the thesis proves out.

Each slice = its own DISCUSS→DESIGN→DELIVER with a flag, same rigor as Loom.

## 7. Risks & watch-items
- **Scope explosion** (7×8 matrix) — mitigate with strict vertical slicing; never build a surface without the stream behind it.
- **AI facet cost/latency/freshness** — the README's open question #1 (citation stewardship) and #3 (facet cadence) are real; pick lazy-generate-on-open + cache + event-driven invalidation, budget-capped.
- **Prod AI constraints** — API embeddings, not local Bumblebee; isolated `restart: :temporary` Oban facet pipeline.
- **Data-model churn** — get `WorkItem`/`WorkItemEvent`/`Facet` shapes right early (they're load-bearing for every surface). Spike before committing the schema.
- **Brand** — "Sous" + kitchen-brigade vocabulary is provisional; don't hard-bake the name.

## 8. Open product questions (from the README + my take)
1. **Citation stewardship** (who keeps AI citations fresh) → tie citation validity to the cited message's edit/delete events; show "stale" if source changed.
2. **Echo dedup scope** → per-channel, 30d memory, dismissible.
3. **Facet cadence** → lazy on viewer-open + cache + invalidate on work-item event. Cost-capped.
4. **Attention defaults** → AI suggests, lead confirms, viewers override (store as facet events).
5. **Customer-voice retention on churn** → keep voices attached to live work items (provenance is the whole point); mark customer churned, don't delete.

## Next step
Confirm the framing (Option 6.1) + pick the first slice (recommend **A**), then run a proper DISCUSS/DESIGN pass on it. The prototypes in `…/design_handoff_sous/design/src/` are the pixel-level visual reference for whichever surface we build.
