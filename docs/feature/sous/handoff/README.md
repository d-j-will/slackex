# Handoff: Sous

> A unified work-stream messaging product for shipping teams (5–100 people) practicing trunk-based development. Real-time chat at the surface; underneath, an event stream that projects into multiple role-shaped views.

## Overview

**Sous** is a Slack/Discord-shaped messaging app with AI features (semantic search, channel summarisation) and a deeper organising idea: every unit of work in the team — changes, decisions, ideas, fixes, customer reports, incidents, hires — is a first-class object on a shared *work stream*. Each role on the team (CEO, CTO, EM, staff engineer, architect, PO, CSM) opens **the same data through a different lens** that delivers right-sized help and *omits what isn't their altitude*.

The kitchen brigade is the operating metaphor throughout: kitchen states (Order → Mise → Pass → Walked), kitchen-brigade calls ("behind", "hands up"), kitchen-brigade roles (chef, sous, expediter, floor). The product itself is the brigade's *sous* — handles what the chef can't see, escalates what they'd want to.

The brand is provisional ("Sous, for now"). The kitchen-brigade vocabulary and the multi-lens architecture are the substance.

## About the Design Files

The files in `design/` are **HTML/JSX prototypes** — high-fidelity design references showing intended look, layout, copy and interactions. They are not production code. Recreate them in the target codebase using its established patterns. For Sous specifically, the assumed stack is **Elixir + Phoenix LiveView + PostgreSQL + pgvector + Claude (Anthropic API)** — see *Tech assumptions* below.

If you choose a different stack, treat the design files as visual + behavioural specification only.

## Fidelity

**High-fidelity.** Final colors, typography, spacing, and copy. Implement pixel-faithfully in your chosen framework. Type stack is Geist (sans) + Geist Mono + Instrument Serif (upright only — no italics). Color palette is warm-charcoal with a golden accent.

---

## Product architecture · the core idea

Everything in Sous is a projection of one underlying **work-item event stream**. A work item has:

```
{
  id, title, kind, state, moved, heat?, customer?,
  people: { lead, supporting[], watching[], stakeholders[] },
  evidence: [{ kind, label }],
  voiceIds: [],                 // customer voices attached
  facets:   { ceo, cto, em, dave, mina, keem, efdp }   // one line per viewer
  attention:{ ceo, cto, em, dave, mina, keem, efdp }   // act|watch|know|hidden
  askFor?:  { <viewerId>: 'specific ask' }
  handsUp?: { from: <userId>, to: <viewerId>, ask }
}
```

A **viewer** is a role-shaped reading angle: CEO, CTO, EM, PO (dave), CSM (mina), Architect (keem), Staff Eng (efdp). Each viewer has a *focus* and a primary *surface*.

Each surface is one projection of the work stream + role-specific data. Switching viewer reshapes every surface — items rise, sink, or disappear; facets re-render; ambient context (SLOs, customer signals, voice quotes) appears or doesn't based on what helps *this* role.

The product's design principle: **help where it's needed.** Right-sized, never noisy. A junior doesn't see SLO burn rates; a CEO doesn't see knn() spans; both see Northbay's renewal risk but with different language and different called-for action.

---

## Surfaces

### 1. Chat (the substrate)
Slack-shaped: workspace with channels + DMs, threaded replies, markdown, emoji reactions, code blocks, link unfurls (rich GitHub PR unfurl with live CI checks).

**Notable elements on the channel canvas:**
- **"On the Loom" ambient strip** at the top of #deploys: live trunk SHA + progress bar, oncall, feature flag state — expandable to CI checks and freeze window. Live ambient awareness.
- **Decision cards** (`/decide`): captured inline in chat with DRI, stakeholders, what / why / next.
- **Customer voice cards**: `&Customer` mentions unfurl with tier / ARR / health / recent reports.
- **Oncall handoff cards** with the avatar-pass animation.
- **Echo dedup hint** above the composer: "this was discussed before · cite jules 9d ago · cite keem 3w ago."

### 2. The Loom — channel summarisation (⌘J)
Right-side drawer with a kitchen-brigade name kept for its poetry. Summarises the active channel into thread-grouped points with **strands** for the voices involved and **citations** back to source messages. Bottom shows model + token cost. Has the woven loader animation.

### 3. The Pass — leadership read (⌘.)
Full-screen overlay. The CEO/CTO/EM expediter's-pass view of the whole organisation. Six sections:
- **Masthead**: "Good morning, X. Walking the pass." + cadence stats (ships / merges / decisions / incidents / MTTR).
- **The thing that mattered**: marquee for the week's biggest shipment.
- **Customers** (only for CEO/EM/CSM): expansion + at-risk + pull-quote.
- **What we shipped**: owner-attributed wins.
- **Decisions**: split into *Made* and *Need your nod*.
- **Pulse**: team-by-team shipping / blocked + mood signals.
- **Risks**: high/medium/low with the *why*.
- **Drop in**: suggested channels with a one-line read.

### 4. The Reduction — efdp's workbench
Staff engineer's distillation surface. Hero idea: every packaged concept sliced into **five lenses** — Principle / Shape / Mechanism / Edges / Ask — each tagged with the audience that can pick it up (jr / sr / pr / po / sme). Three states per lens (firm / sketched / open).

Sections: Today's reduction, In the pot (ideas at various stages), Tensions (unresolved questions), Carried (handed off).

### 5. The Stack — keem's perch
Architect's view. Hero is the **horizon table**: every release in the ecosystem this week × what we run × keem's read on whether to act. Plus the stack proper (5 layers · current/lag), Library (reading list with marginalia), Bench (evals run), Chewing (open questions).

### 6. The Expo — dave's PO station
Three movements top-to-bottom:
- **Listening**: raw customer voices grouped by customer, with provenance.
- **Shaping**: themes (clusters of voices) → Orders (drafts with the customer voice attached as evidence).
- **On the line**: orders pushed to the work stream, with original voices carried through; walked orders with "tell them" prompts.

**Hero idea: customer voice rides through every work item to ship.** When a PR merges six weeks later, the original customer quote that started it is still attached. No more "why did we build this?" amnesia.

### 7. The Floor — mina's CSM station
Three movements: read the room → spot moments → carry the wins. Customer health tiles, moments (risk/expansion/testimonial), call sheet (today/this week/recent), renewal+expansion calendar, "from the kitchen" panel of recently walked work with prepared CSM notes.

### 8. In Service — the work stream itself (⌘L)
Full-screen overlay. The unified work-in-flight surface. Four columns (Order / Mise / Pass / Walked). Each card is one work item, rendered through the active viewer's facet. **Attention treatment**:
- `act` — accent edge, full prose, "behind" tag, rises to top
- `watch` — default
- `know` — dashed border, dimmed, one-line compact
- `hidden` — not rendered; peek toggle "+N not at your altitude"

**Click any card → Facet Drawer**: same atom through all six prisms side-by-side, each viewer's attention pill, hidden facets shown as dashed-italic "not at this altitude". This is the demo moment.

Bottom ambient strip: SLO budget chips (only for CTO/EM/Architect), pager state (always), peek-hidden toggle.

---

## Design tokens

```css
/* Warm-charcoal palette */
--bg-deep:     #0b0a07;
--bg:          #131109;
--surface:     #1b1810;
--surface-2:   #221e15;
--line:        rgba(232, 220, 185, 0.10);
--line-strong: rgba(232, 220, 185, 0.18);

--text:        #f2ecdc;
--text-2:      #b8af96;
--text-3:      #80785f;
--text-4:      #56503e;

--accent:      #e8c547;   /* golden */
--accent-soft: rgba(232, 197, 71, 0.33);
--accent-wash: rgba(232, 197, 71, 0.08);

--copper:      #d97757;
--jade:        #6fb59a;
--rose:        #c98aa6;
--ok:          #7fb59a;
--error:       #e07c6e;

/* Layout */
--sidebar-w: 280px;
--thread-w: 420px;
--radius: 10px;
--radius-sm: 7px;

/* Type */
--ff-sans:  "Geist", system-ui, sans-serif;
--ff-mono:  "Geist Mono", ui-monospace, monospace;
--ff-serif: "Instrument Serif", Georgia, serif;
```

**No italics anywhere.** `em { font-style: normal }` is globally enforced. Upright Instrument Serif remains as an option for masthead titles via a `.is-serif` modifier.

---

## Viewer model

Each user has a viewer role with `id`, `name`, `role`, `initial`, `color`, `focus` (array), `surface` (primary).

| Viewer | Role  | Surface       | Color    | Focus                                |
|--------|-------|---------------|----------|--------------------------------------|
| ceo    | CEO   | the Pass      | #d97757  | customers · decisions · risks · wins |
| cto    | CTO   | the Pass      | #7c5cff  | shipping · risks · decisions · pulse |
| em     | EM    | the Pass      | #3ecf8e  | pulse · decisions · blockers         |
| keem   | Arch  | the Stack     | #3ecf8e  | stack · horizon · bench              |
| efdp   | Staff | the Reduction | #7c5cff  | distill · package · tension          |
| dave   | PO    | the Expo      | #d97757  | voice · shape · customers            |
| mina   | CSM   | the Floor     | #ff8fbf  | health · moments · calls · renewals  |

The "Reading as" switcher is visible in every surface's top bar. Switching viewer re-shapes every surface immediately.

---

## Phasing · a buildable roadmap

### Phase 1 — Chat substrate (foundation)
- Phoenix LiveView app with workspaces · channels · DMs · threads
- Markdown (bold/italic/strike/code/links/headings/blockquote/lists/code blocks)
- Message reactions, mentions (`@user`, `&customer`), unread state
- Real-time presence via Phoenix.PubSub
- Channel browser, command palette (⌘K) with semantic search via pgvector

### Phase 2 — The Loom (channel summarisation)
- `Sous.AI.Summary` with chunked map-reduce (`@chunk = 256`, bounded `Task.async_stream`)
- Streaming output via LiveView async assigns
- Citation expansion (parent message included when a summary point spans a thread boundary)
- Strand visualisation for voices in summary
- `claude-haiku-4-5` for the model; budget for ~4k tokens per summary

### Phase 3 — Work-item event stream
This is the heart. Implement first as an append-only event log:
- `WorkItem` schema with `kind`, `state`, `moved_at`, `people` (jsonb), `evidence` (jsonb), `voice_ids` (uuid array)
- `WorkItemEvent` log table — every state transition, every facet update is an event
- Projections: build read models for each surface as Ecto views or GenServers subscribing to events
- `/decide` slash command in the composer creates a `WorkItem` of kind `:decision` in state `:mise` with the thread as provenance

### Phase 4 — Viewer-aware facets + attention
- `Sous.Facets` module: per-(viewer, work_item) `facet` (text) + `attention` (`:act | :watch | :know | :hidden`)
- Initial facets generated by Claude from the work item + viewer prompt; editable inline
- `Sous.Web.WorkItemLive` renders the facet+attention for the current viewer; switching viewer reshapes
- Facet Drawer shows all six prisms side-by-side

### Phase 5 — Surface views (compose against the stream)
- `the Pass`, `the Reduction`, `the Stack`, `the Expo`, `the Floor`, `In Service` — each is a LiveView that subscribes to the work-item stream and applies its viewer-specific filtering/grouping
- Customer voice ingestion (manual at first, then Zendesk/Pylon/in-app feedback connectors later)
- "Voice carries through": when a `WorkItem` is created from voice, persist `voice_ids` and surface them everywhere downstream

### Phase 6 — Ambient + integrations
- "On the Loom" strip: subscribe to GitHub releases, Hex updates, your CI/CD pipeline
- Customer health: nightly job computing per-customer health from signals
- Pager handoffs: PagerDuty integration

---

## Data model · canonical entities

```elixir
WorkItem
  id, title, kind, state, moved_at, heat
  customer_id (optional)
  people (jsonb) — lead, supporting, watching, stakeholders
  evidence (jsonb) — list of {kind, label}
  voice_ids (uuid[]) — references VoiceItem
  events (has_many WorkItemEvent)

WorkItemFacet
  work_item_id, viewer_id  (composite PK)
  attention :: enum [:act, :watch, :know, :hidden]
  facet_text :: text
  ask_for :: text (optional)
  hands_up_to :: viewer_id (optional)
  hands_up_ask :: text
  updated_at

VoiceItem        — a customer voice unit
  customer_id, contact_name, contact_role
  kind :: enum [:support, :call, :nps, :interview, :in_app]
  sentiment :: enum [:positive, :request, :mixed, :negative, :risk, :neutral]
  text, source_url, captured_by, captured_at
  theme_id (nullable)

Theme            — semantic cluster of voices
  title, customer_ids[], sentiment, state
  order_id (nullable)        — link to the Order shaped from this theme

Order            — PO-shaped work, may or may not be pushed
  title, state :: enum [:shaping, :drafted, :pushed, :walked]
  work_item_id (nullable when shaping/drafted)
  why, what, so_that, size_estimate
  voice_ids[], theme_ids[], customer_ids[]

Customer
  name, tier, arr, health, csm_user_id
  contract_end, expansion_potential, renewal_prob
  contacts (jsonb)
  signals (jsonb) — usage/voice/risk markers

Viewer (user role)
  user_id, role, color, focus[], primary_surface

Channel · Message · Thread · Reaction
  standard Slack-shape

Decision
  work_item_id (always linked)
  what, why, next (jsonb), dri_user_id, stakeholders[]
  posted_in_channel, posted_in_thread
```

---

## Interactions of note

- **Viewer switch animation**: when you change "Reading as", cards in In Service animate to their new positions (rising/sinking by attention rank). Use FLIP technique or `<motion>` if available.
- **The Loom loader**: warp/weft SVG with the weft threads animating across (replaces spinner). Reusable for any AI inference.
- **Decision card creation**: typing `/decide` in the composer opens a 3-field modal (What / Why / Next), stakeholders pre-filled from thread participants. On submit, posts to channel **and** creates a `WorkItem`. The card in chat shows a small "lives in: In Service" link.
- **"Tell them" affordances**: on walked work items touching a customer, surface in The Floor with a prepared note + "Send now" / "Draft" buttons.
- **Hands up**: a card author can mark an item as needing help from a specific viewer. Visually: copper "hands up" pill + footer panel with the request.

---

## Tech assumptions

- **Elixir 1.17+** / **Erlang OTP 27+**
- **Phoenix 1.7+** / **LiveView 0.20+** (or 1.0 when stable)
- **PostgreSQL 16+** with **pgvector 0.7+**
- **Anthropic API** for `claude-haiku-4-5` (summaries, facets, echo dedup)
- **OpenTelemetry** for tracing
- **Tailwind** for styling — port the design tokens above into `tailwind.config.js`
- **Oban** for background jobs (embedding ingestion, nightly health computation)
- **Phoenix.PubSub** for real-time fan-out

---

## What's deliberately deferred

- Mobile (web first; mobile is a different read)
- Customer-facing outward projection (showing customers their own work)
- Permission / ACL granularity (assume workspace-level for v1)
- Billing
- Compliance (SOC2, etc — defer to post-MVP)
- Brand identity (woven mark is placeholder; "Sous" is placeholder name)

---

## Files in this handoff

- `design/Sous.html` — entry point; opens the chat substrate with #deploys active
- `design/src/*.jsx` — React/JSX prototypes of every surface (Babel-transpiled in browser)
- `design/src/*.css` — design system + per-surface styles
- `design/src/data.js` — canonical mock data: USERS, CUSTOMERS, WORK_ITEMS, VOICE, THEMES, ORDERS, plus per-surface data structures (TAPESTRY, REDUCTION, STACK, EXPO, FLOOR, IN_SERVICE)

The prototypes are runnable: open `design/Sous.html` in a browser to interact with every surface, switch viewers via the Tweaks panel (toolbar toggle) → *Reading as: X*, and use keyboard shortcuts (⌘K palette, ⌘J Loom, ⌘. Pass, ⌘L In Service).

---

## Open questions for the implementer

These are real product questions that surfaced during design and are deferred:

1. **Citation stewardship** — when an AI surface (Loom, Pass, Echo) cites a chat message, who owns the freshness of that citation? See `WORK_ITEMS.find(w => w.id === 'w-stewardship')` and `efdp`'s working note.
2. **Echo dedup scope** — per-question or per-channel dismissal? 30d memory?
3. **Facet generation cadence** — facets pre-computed on work-item events, or generated lazily on viewer open? (Latency vs. cost trade-off.)
4. **Attention defaults** — who decides initial `attention` for a new work item? AI suggests, lead confirms, viewers can override?
5. **Customer voice retention** — when a customer churns, what happens to their voice attached to live work items?
