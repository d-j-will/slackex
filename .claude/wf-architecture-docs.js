export const meta = {
  name: 'architecture-docs',
  description: 'Generate a comprehensive multi-zoom architecture doc set for Slackex (read-only; writes only docs/architecture/*.md)',
  phases: [
    { title: 'Survey', detail: 'Map global facts: supervision tree, PubSub topics, Oban queues, feature flags, schemas' },
    { title: 'Author', detail: 'Per doc: explore code -> write in house style -> verify against code' },
    { title: 'Index', detail: 'Write README index + completeness critic over all lib/slackex contexts' },
  ],
}

const ROOT = '/Volumes/Personal/Users/davidwilliams/dev/elixir/slackex'
const DIR = `${ROOT}/docs/architecture`

// House style every writer must follow, modeled on the existing gold-standard docs.
const STYLE = `
HOUSE STYLE (match docs/architecture/realtime-chat.md exactly -- open and read it first as the gold standard):
- Title as H1. Then numbered H2 sections: "## 1. Overview", "## 2. C4 Diagrams", etc.
- Include C4 diagrams in Mermaid fenced blocks (\`\`\`mermaid). At minimum a System Context and/or Container
  diagram showing where this subsystem sits. Add sequence diagrams for key flows.
- Sections to include where relevant: Overview; C4 Diagrams (Context/Container/Component); Main Components;
  key runtime flows as sequence diagrams; Key Design Properties; Data Model (if it owns tables); Failure Modes
  & Resilience (how it degrades, restart strategy, blast radius); Code Map (table of file -> responsibility);
  Related Documents (relative links).
- Be precise and grounded in the actual code. Cite real module names and file paths (e.g. \`lib/slackex/chat/message.ex\`).
  Use file_path style references. NEVER invent functions, modules, flags, or tables -- if unsure, omit it.
- Prose explains the WHY (the surprising/non-obvious rationale), not just the what.
- Cross-reference sibling docs by relative path so the set forms a navigable web.
`

// Hard-won, incident-derived design intentions. These are LEADS TO VERIFY, not gospel.
const GROUND_TRUTH = `
DESIGN INTENTIONS FROM INCIDENT HISTORY (these are leads -- VERIFY each against the actual source before
asserting it; where the code diverges or a mechanism is NOT implemented, document what is actually there and
flag the gap; never assert a mechanism you cannot find in the code):
- Snowflake IDs order messages; messages table is PARTITIONED. Partition pruning needs composite joins
  like (message_id, message_inserted_at) = (id, inserted_at).
- Messages use Cloak encryption at rest. A plaintext companion column \`search_content\` enables GIN/FTS indexing.
- Search authorization uses EXISTS subqueries, NOT JOINs, to avoid row duplication that corrupts rank/pagination.
- Hybrid search fuses FTS + semantic via Reciprocal Rank Fusion (RRF). UI labels: "Best match"=hybrid,
  "Exact words"=text, "Meaning"=semantic.
- Embeddings: BumblebeeClient (all-MiniLM-L6-v2, 384-dim) in dev; StubClient in prod (GPU off-limits, CPU EXLA OOMs the LXC).
  Non-essential supervisors use restart: :temporary to prevent cascade (v0.5.36 outage precedent).
- Oban worker perform/1 must return the result (never \`_ = result; :ok\`) so Oban retries on failure.
- Req streaming (into: :self) yields raw Mint messages; must use Req.parse_message/2. (v0.5.58-61 precedent.)
- pipeline:events is a PubSub bridge that must have a real producer->consumer path (integration-tested), not faked.
- on_conflict: :nothing returns {:ok, %Struct{id: nil}} on conflict -> must re-fetch.
- Multi-node is real: deps are libcluster + horde + dns_cluster; Cluster.Supervisor is started in application.ex;
  ChannelServer/ChannelRegistry/ChannelSupervisor live in lib/slackex/messaging/ and use Horde; lib/slackex/node_listener.ex
  handles :nodeup/:nodedown. Describe the ACTUAL behavior you find (what node_listener and batch_writer really do) rather
  than asserting a grand "split-brain fencing" design unless the code clearly implements it.
- Feature flags via FunWithFlags gate ALL surfaces (context + LiveView + routes).
`

// The full doc set (NEW files only -- existing docs are kept and cross-referenced, never overwritten).
// level: L0 (landscape) | L1 (subsystem) | L2 (deep dive) | X (cross-cutting)
const DOCS = [
  { file: 'system-landscape.md', level: 'L0', title: 'System Landscape',
    scope: 'Whole-application C4 System Context + Container. The Phoenix endpoint, LiveView tier, all bounded contexts (Accounts, Chat, Messaging, Search, Embeddings, AI, Notifications, Integrations, Sous, Factory, Links, Analytics), data stores (Postgres + pgvector, Redis), Oban, Phoenix.PubSub, OTEL pipeline, and external systems. The OTP supervision tree from application.ex (essential vs :temporary). Runtime topology (multi-node, libcluster, Horde). Cross-cutting concerns: encryption, feature flags, observability, snowflake IDs. This is the entry-point map; keep subsystem detail shallow and link out to L1 docs.',
    explore: 'lib/slackex/application.ex, lib/slackex_web/endpoint.ex, lib/slackex_web/router.ex, config/, mix.exs (deps), the public facade of each lib/slackex/<context> dir' },

  // --- L1 subsystems ---
  { file: 'chat.md', level: 'L1', title: 'Chat Context',
    scope: 'The Slackex.Chat bounded context: channels, messages, members, moderation, DMs. Public facade, sub-modules, lifecycle. Note the per-channel process model lives in Slackex.Messaging (ChannelServer) -- describe the boundary and link to message-pipeline-and-persistence.md for the process layer, plus realtime-chat.md (send path), threads-and-reactions.md, and chat-domain-as-is-to-be.md (refactor proposal) rather than duplicating them.',
    explore: 'lib/slackex/chat/ (all 25 files), lib/slackex/chat.ex' },
  { file: 'accounts-and-auth.md', level: 'L1', title: 'Accounts & Authentication',
    scope: 'Slackex.Accounts context: users, registration, sessions, Guardian/auth, profiles, online status, is_bot flag. Auth LiveViews and router pipelines. Password hashing (bcrypt).',
    explore: 'lib/slackex/accounts/, lib/slackex/accounts.ex, lib/slackex_web/live/auth_live/, router auth pipelines' },
  { file: 'message-pipeline-and-persistence.md', level: 'L1', title: 'Message Pipeline & Persistence',
    scope: 'Slackex.Messaging + Slackex.Pipeline: how a message goes from send to durable, ordered, encrypted storage. Batched persistence, Snowflake ID assignment, the pipeline:events PubSub bridge, partitioned messages table. Complements realtime-chat.md (which covers the LiveView/PubSub send path) by focusing on persistence and the pipeline.',
    explore: 'lib/slackex/messaging/ (channel_server.ex, channel_supervisor.ex, channel_registry.ex, envelope.ex), lib/slackex/pipeline/batch_writer.ex, lib/slackex/infrastructure/snowflake.ex, lib/slackex/chat/message.ex, priv/repo/migrations (partitioning)' },
  { file: 'search-and-intelligence.md', level: 'L1', title: 'Search & Intelligence',
    scope: 'Slackex.Search context: full-text search, semantic/vector search, hybrid RRF fusion, RAG. Query building, EXISTS authorization, ranking, the :message_search feature flag. Link to deep-dive-hybrid-rrf-search.md.',
    explore: 'lib/slackex/search/, lib/slackex/search.ex, lib/slackex/chat/message.ex (search_content)' },
  { file: 'embeddings.md', level: 'L1', title: 'Embeddings Subsystem',
    scope: 'Slackex.Embeddings context: BumblebeeClient vs StubClient, the embedding worker pipeline, backfill task, pgvector storage, dimensionality (384), OTP resilience (restart: :temporary). Why GPU is off-limits in prod. Link to deep-dive-embedding-resilience.md.',
    explore: 'lib/slackex/embeddings/ (all 12 files), lib/slackex/embeddings.ex' },
  { file: 'ai-summarization.md', level: 'L1', title: 'AI & Summarization',
    scope: 'Slackex.AI context: LLM clients, conversation/DM summarization, streaming responses (Req into: :self + Mint), prompt construction. Resilience and feature gating. Link to deep-dive-req-streaming.md.',
    explore: 'lib/slackex/ai/, lib/slackex/ai.ex' },
  { file: 'integrations.md', level: 'L1', title: 'Integrations (Webhooks & MCP)',
    scope: 'Slackex.Integrations context: incoming webhooks (POST /api/webhooks/:token, bot users, hashed tokens, payload limits) and the MCP server (agent-facing messaging, SSE). How both flow through the ChannelServer pipeline. Reference the feature design docs under docs/feature/incoming-webhooks and docs/feature/mcp-server.',
    explore: 'lib/slackex/integrations/, lib/slackex/integrations.ex, router (api/webhooks, mcp), lib/slackex_web for webhook/mcp controllers' },
  { file: 'sous.md', level: 'L1', title: 'Sous (Decision Event-Sourcing)',
    scope: 'Slackex.Sous context: the event-sourced decision feature (/decide modal -> decision cards -> In Service board). Commands, events, projections, viewer model, facet drawer. Link to deep-dive-event-sourcing-sous.md and the docs/feature/sous specs.',
    explore: 'lib/slackex/sous/ (all 11 files), lib/slackex/sous.ex, lib/slackex_web/live/sous_live/' },
  { file: 'dark-factory.md', level: 'L1', title: 'Dark Factory',
    scope: 'Slackex.Factory context: the factory run/work coordination system exposed via MCP (queue_factory_run, claim_factory_work, heartbeat, submit_result, verification). Worktree-isolated agent execution. Reference docs/feature/dark-factory/design.',
    explore: 'lib/slackex/factory/, lib/slackex/factory.ex, docs/feature/dark-factory/design/' },
  { file: 'links-and-previews.md', level: 'L1', title: 'Links & Link Previews',
    scope: 'Slackex.Links context: URL extraction, link preview fetching/unfurling, the LinkPreviewWorker, caching, and how previews attach to messages via the pipeline.',
    explore: 'lib/slackex/links/ (all 7 files), lib/slackex/links.ex' },
  { file: 'content-and-markdown.md', level: 'L1', title: 'Content Rendering & Markdown',
    scope: 'Slackex.Markdown: Earmark + custom Scrubber + chat preprocessor, the :markdown_rendering flag, XSS handling at render time, custom .prose CSS, decode_html_entities backfill, the static-analysis test guarding raw(). Reference docs/feature/markdown-rendering.',
    explore: 'lib/slackex/markdown/, lib/slackex/markdown.ex, docs/feature/markdown-rendering/design/' },
  { file: 'encryption-at-rest.md', level: 'L1', title: 'Encryption at Rest',
    scope: 'Slackex.Encrypted: Cloak vaults, encrypted Ecto field types, key management, the plaintext search_content companion pattern that reconciles encryption with FTS. Reference docs/feature/encryption-at-rest. Link to deep-dive-encrypted-fields-fts.md.',
    explore: 'lib/slackex/encrypted/, config for cloak, lib/slackex/chat/message.ex' },
  { file: 'analytics.md', level: 'L1', title: 'Analytics',
    scope: 'Slackex.Analytics context + the AnalyticsTracker LiveView hook: what events are captured, the analytics-enabled gating, storage, and how it stays non-blocking/non-essential.',
    explore: 'lib/slackex/analytics/, lib/slackex/analytics.ex, lib/slackex_web/live/analytics_tracker.ex, lib/slackex_web/live/admin_live/' },
  { file: 'caching-and-read-model.md', level: 'L1', title: 'Caching & Read Model',
    scope: 'Slackex.Cache + Slackex.ReadRepo: the read-side / CQRS read model, in-process or Redis caching, cache invalidation, and edge caching (Cloudflare cache-control headers + auto-purge on deploy).',
    explore: 'lib/slackex/cache/, lib/slackex/read_repo/, config, lib/slackex_web for cache-control plug/headers' },
  { file: 'observability-and-ops.md', level: 'L1', title: 'Observability & Operations',
    scope: 'Slackex.Ops + the OTEL/metrics stack: traces (OTEL Collector -> Tempo), Prometheus metrics (/metrics), Grafana dashboards, telemetry pollers, contract tests for metric names. Pinned infra versions. Reference docs/runbooks/observability.md.',
    explore: 'lib/slackex/ops/, lib/slackex_web/telemetry.ex, infra/, config for opentelemetry, docs/runbooks/observability.md' },
  { file: 'web-and-liveview.md', level: 'L1', title: 'Web Tier & LiveView',
    scope: 'Slackex_web architecture: router and pipelines, the LiveView modules (chat_live, sous_live, admin_live, auth_live), core components, JS hooks, Phoenix Channels, presence, reconnect/catchup, and the PWA (manifest, service worker, install banner). The god-LiveView (ChatLive.Index) and the planned decomposition.',
    explore: 'lib/slackex_web/router.ex, lib/slackex_web/live/, lib/slackex_web/components/, assets/js/, lib/slackex_web/endpoint.ex' },

  // --- L2 deep dives ---
  { file: 'deep-dive-hybrid-rrf-search.md', level: 'L2', title: 'Deep Dive: Hybrid RRF Search',
    scope: 'The Reciprocal Rank Fusion algorithm fusing FTS and vector results, the SQL (EXISTS-based authorization, ranking, pagination correctness), how the three modes (hybrid/text/semantic) map to queries, and edge cases.',
    explore: 'lib/slackex/search/, lib/slackex/chat/message.ex, relevant migrations (GIN index, pgvector)' },
  { file: 'deep-dive-embedding-resilience.md', level: 'L2', title: 'Deep Dive: Embedding Pipeline Resilience',
    scope: 'OTP supervision design for embeddings: restart: :temporary, dedicated supervisor, blast-radius isolation, the v0.5.36 cascade incident and how the architecture now prevents it. Dev vs prod client selection. The EXLA_TARGET=host compile-time constraint.',
    explore: 'lib/slackex/embeddings/, lib/slackex/application.ex, docs/rca/2026-03-05-embedding-cascade-app-crash.md' },
  { file: 'deep-dive-event-sourcing-sous.md', level: 'L2', title: 'Deep Dive: Sous Event Sourcing & CQRS',
    scope: 'The event-sourcing tracer: command -> event -> projection flow, the event store schema, projections/read models, viewer-specific state, replay, and the ADR(s). Why ES/CQRS was chosen for this slice.',
    explore: 'lib/slackex/sous/, docs/feature/sous/, any ADR files for sous' },
  { file: 'deep-dive-encrypted-fields-fts.md', level: 'L2', title: 'Deep Dive: Encrypted Fields with Full-Text Search',
    scope: 'The tension between Cloak encryption and searchability, resolved via the plaintext search_content companion column + GIN index. Write path (how both columns stay in sync), threat model trade-off, and migration history.',
    explore: 'lib/slackex/encrypted/, lib/slackex/chat/message.ex, migrations adding search_content + GIN' },
  { file: 'deep-dive-pipeline-events-bridge.md', level: 'L2', title: 'Deep Dive: The pipeline:events Bridge',
    scope: 'The PubSub bridge from message persistence to downstream consumers (link previews, embeddings). Producer and consumer wiring, the v0.5.47-64 dead-topic incident, and the integration-test requirement that proves the bridge exists.',
    explore: 'lib/slackex/pipeline/, listeners (*_listener.ex), lib/slackex/messaging/, docs/rca/2026-03-06-pipeline-events-bridge-missing.md' },
  { file: 'deep-dive-snowflake-partitioning.md', level: 'L2', title: 'Deep Dive: Snowflake IDs & Table Partitioning',
    scope: 'Snowflake ID generation (structure, ordering guarantees, generator process), the partitioned messages table, partition pruning via composite joins, and pagination/ordering correctness.',
    explore: 'lib/slackex/infrastructure/snowflake.ex, lib/slackex/infrastructure.ex, lib/slackex/chat/message.ex, lib/slackex/chat/messages.ex, migrations for partitioning' },
  { file: 'deep-dive-multi-node-horde.md', level: 'L2', title: 'Deep Dive: Multi-Node & Horde',
    scope: 'Distributed runtime: libcluster topology, Horde distributed supervisor/registry for ChannelServer, split-brain fencing, failover behavior, and PubSub across nodes. Why the app is multi-node and what the failure modes are.',
    explore: 'lib/slackex/application.ex, config (libcluster topologies), lib/slackex/messaging/channel_server.ex, lib/slackex/messaging/channel_supervisor.ex, lib/slackex/messaging/channel_registry.ex, lib/slackex/node_listener.ex, lib/slackex/pipeline/batch_writer.ex' },
  { file: 'deep-dive-req-streaming.md', level: 'L2', title: 'Deep Dive: Streaming LLM Responses (Req into: :self)',
    scope: 'The Req into: :self streaming pattern: raw Mint messages, Req.parse_message/2, async response struct, cleanup with Req.cancel_async_response, and the v0.5.58-61 zero-token incident and fix.',
    explore: 'lib/slackex/ai/, docs/rca/2026-03-06-summarization-streaming-failure.md' },

  // --- Cross-cutting ---
  { file: 'data-model-erd.md', level: 'X', title: 'Data Model & ERD',
    scope: 'An entity-relationship overview of the major Ecto schemas and their relationships (users, channels, messages, members, dm_conversations, reactions, threads, embeddings, decisions/events, webhooks, device tokens, etc.). Mermaid erDiagram. Note partitioned and encrypted tables. Group by bounded context.',
    explore: 'all lib/slackex/**/*.ex schema modules (use grep for "use Ecto.Schema"), priv/repo/migrations/' },
  { file: 'deployment-topology.md', level: 'X', title: 'Deployment Topology',
    scope: 'How the system is built and deployed: GitHub Actions CI/CD, GHCR images, SSH-to-LXC deploy, caddy-docker-proxy reverse proxy, the unprivileged LXC on Proxmox, multi-node prod, Release.migrate, Cloudflare. Mermaid deployment diagram. Reference docs/runbooks/deployment.md.',
    explore: '.github/workflows/ci-deploy.yml, docs/runbooks/deployment.md, rel/, Dockerfile, docker-compose*.yml, config/runtime.exs' },
  { file: 'feature-flags-and-lifecycle.md', level: 'X', title: 'Feature Flags & Lifecycle',
    scope: 'The FunWithFlags-based feature flag system: how flags gate context + LiveView + routes, the flag lifecycle (add gated -> roll out -> clean up), the /new-feature scaffold, and a current inventory of known flags (:message_search, :markdown_rendering, :incoming_webhooks, :push_notifications, :catchup_on_reconnect, :sous, etc.).',
    explore: 'grep for FunWithFlags across lib/, config for fun_with_flags, lib/slackex_web for flag gating patterns' },
]

// Pilot mode: pass args { pilot: ["chat.md", "deep-dive-multi-node-horde.md"] } to validate the pipeline
// on a representative L1 + the riskiest L2 before fanning out to all docs. Index phase is skipped in pilot.
const PILOT = args && Array.isArray(args.pilot) ? args.pilot : null
const DOC_SET = PILOT ? DOCS.filter(d => PILOT.includes(d.file)) : DOCS

const SURVEY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    supervisionTree: { type: 'string', description: 'Markdown summary of application.ex children, essential vs restart:temporary, supervisors and their purpose' },
    pubsubTopics: { type: 'array', items: { type: 'string' }, description: 'PubSub topic names and what flows on them' },
    obanQueues: { type: 'array', items: { type: 'string' }, description: 'Oban queues and their workers' },
    featureFlags: { type: 'array', items: { type: 'string' }, description: 'FunWithFlags flag names found in code' },
    schemas: { type: 'array', items: { type: 'string' }, description: 'Ecto schema module -> table name pairs' },
    externalDeps: { type: 'array', items: { type: 'string' }, description: 'External systems/services and key libraries' },
    topologyNotes: { type: 'string', description: 'Runtime topology: clustering, Horde, nodes, data stores' },
  },
  required: ['supervisionTree', 'pubsubTopics', 'obanQueues', 'featureFlags', 'schemas', 'externalDeps', 'topologyNotes'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    file: { type: 'string' },
    accurate: { type: 'boolean', description: 'true if the doc is factually grounded in the code after any fixes you applied' },
    hasMermaid: { type: 'boolean', description: 'true if the doc contains at least one mermaid diagram' },
    issuesFound: { type: 'array', items: { type: 'string' } },
    fixesApplied: { type: 'array', items: { type: 'string' } },
  },
  required: ['file', 'accurate', 'hasMermaid', 'issuesFound', 'fixesApplied'],
}

const CRITIC_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    coveredContexts: { type: 'array', items: { type: 'string' } },
    gaps: { type: 'array', items: { type: 'string' }, description: 'lib/slackex contexts or notable features with no architecture doc coverage' },
    suggestions: { type: 'array', items: { type: 'string' } },
  },
  required: ['coveredContexts', 'gaps', 'suggestions'],
}

// ---------------------------------------------------------------------------
phase('Survey')
log('Surveying global architecture facts across the codebase...')

const surveyParts = await parallel([
  () => agent(
    `You are mapping the Slackex Elixir/Phoenix app at ${ROOT}. Produce a precise global facts sheet for architecture documentation.\n` +
    `Read lib/slackex/application.ex (the supervision tree), lib/slackex_web/endpoint.ex, config/*.exs, and mix.exs.\n` +
    `Identify: the OTP supervision tree (children, which are essential vs restart: :temporary, dedicated supervisors and why), ` +
    `Oban queues + workers, external dependencies and key libraries, and runtime topology (libcluster/Horde/multi-node/data stores).\n` +
    `Be exhaustive and accurate. Cite module names and file paths. Do NOT modify any files.`,
    { label: 'survey:runtime', phase: 'Survey', agentType: 'Explore', schema: {
      type: 'object', additionalProperties: false,
      properties: {
        supervisionTree: { type: 'string' }, obanQueues: { type: 'array', items: { type: 'string' } },
        externalDeps: { type: 'array', items: { type: 'string' } }, topologyNotes: { type: 'string' },
      }, required: ['supervisionTree', 'obanQueues', 'externalDeps', 'topologyNotes'] } }
  ),
  () => agent(
    `You are mapping the Slackex Elixir/Phoenix app at ${ROOT}. Produce a precise data + messaging facts sheet.\n` +
    `Grep lib/ for "use Ecto.Schema" to enumerate every schema module and its table name. Grep for "Phoenix.PubSub" / "broadcast(" / "subscribe(" to list PubSub topics and what flows on them. ` +
    `Grep for "FunWithFlags" to list every feature flag name.\n` +
    `Be exhaustive and accurate. Cite module names and file paths. Do NOT modify any files.`,
    { label: 'survey:data', phase: 'Survey', agentType: 'Explore', schema: {
      type: 'object', additionalProperties: false,
      properties: {
        schemas: { type: 'array', items: { type: 'string' } }, pubsubTopics: { type: 'array', items: { type: 'string' } },
        featureFlags: { type: 'array', items: { type: 'string' } },
      }, required: ['schemas', 'pubsubTopics', 'featureFlags'] } }
  ),
]).then(r => r.filter(Boolean))

const facts = JSON.stringify(Object.assign({}, ...surveyParts), null, 1).slice(0, 6000)
log(`Survey complete. Authoring ${DOC_SET.length} document(s)${PILOT ? ' [PILOT]' : ''} in parallel pipelines...`)

// ---------------------------------------------------------------------------
phase('Author')

const results = await pipeline(
  DOC_SET,
  // Stage 1: explore the code area for this doc
  (doc) => agent(
    `You are researching code to support an architecture document for the Slackex app at ${ROOT}.\n` +
    `DOCUMENT: "${doc.title}" (${doc.level})\n` +
    `SCOPE: ${doc.scope}\n` +
    `START BY READING: ${doc.explore}\n\n` +
    `Trace the real implementation: public API/facade, key modules and their responsibilities, runtime flows ` +
    `(who calls whom, what processes exist, what PubSub/Oban is involved), data model (tables/schemas it owns), ` +
    `dependencies on other contexts, failure modes, and anything genuinely interesting or non-obvious.\n` +
    `GLOBAL FACTS (for consistency): ${facts}\n` +
    `Return DETAILED, ACCURATE notes a technical writer can turn into a doc: concrete module names, file paths, ` +
    `function names, flows, and the WHY behind design choices. Do NOT modify any files.`,
    { label: `explore:${doc.file}`, phase: 'Author', agentType: 'Explore' }
  ),
  // Stage 2: write the doc in house style
  (intel, doc) => agent(
    `Write a complete architecture document and save it to ${DIR}/${doc.file} using the Write tool.\n` +
    `DOCUMENT: "${doc.title}" (zoom level ${doc.level})\n` +
    `SCOPE: ${doc.scope}\n\n` +
    `RESEARCH NOTES from a code exploration (ground every claim in these + your own reads of the cited files):\n${intel}\n\n` +
    STYLE + GROUND_TRUTH +
    `\nIMPORTANT RULES:\n` +
    `- This is a READ-ONLY documentation task. The ONLY file you may write is ${DIR}/${doc.file}. NEVER edit application code.\n` +
    `- Verify specifics by Reading the actual source files before asserting them. If you cannot confirm something, leave it out.\n` +
    `- Include at least one Mermaid diagram (C4 and/or sequence/ER as appropriate to the zoom level).\n` +
    `- End with a "Related Documents" section linking sibling docs in docs/architecture/ by relative path.\n` +
    `Return the absolute path written and a one-line summary.`,
    { label: `write:${doc.file}`, phase: 'Author' }
  ),
  // Stage 3: verify the written doc against the code (separate reviewer agent; may apply factual fixes)
  (_writeSummary, doc) => agent(
    `You are a technical reviewer verifying an architecture document against the actual code. Do NOT trust the doc; check it.\n` +
    `DOC: ${DIR}/${doc.file}\n` +
    `Read the doc, then read the relevant source under ${ROOT} (scope: ${doc.scope}; start: ${doc.explore}).\n` +
    `Check: (1) every module/function/flag/table named actually exists; (2) flows and design claims match the code; ` +
    `(3) it does not contradict the incident-verified facts; (4) it contains at least one valid mermaid diagram; ` +
    `(5) Mermaid syntax is well-formed.\n` +
    `If you find factual errors, FIX them directly with Edit on ${DIR}/${doc.file} (this is the only file you may modify; never touch code). ` +
    `Prefer deleting an unverifiable claim over leaving it wrong.\n` +
    `Return your verdict.`,
    { label: `verify:${doc.file}`, phase: 'Author', schema: VERIFY_SCHEMA }
  ),
).then(r => r.filter(Boolean))

// ---------------------------------------------------------------------------
if (PILOT) {
  return {
    pilot: PILOT,
    docsWritten: results.length,
    inaccurate: results.filter(r => r && !r.accurate).map(r => r.file),
    missingMermaid: results.filter(r => r && !r.hasMermaid).map(r => r.file),
    verdicts: results,
  }
}

phase('Index')
log('Writing README index and running completeness critic...')

const fileList = DOCS.map(d => `- ${d.level} | ${d.file} | ${d.title} | ${d.scope.slice(0, 90)}`).join('\n')

await agent(
  `Rewrite the architecture docs index at ${DIR}/README.md using the Write tool.\n` +
  `The index must present a clear ZOOM-LEVEL reading map for the full doc set. There are FOUR levels:\n` +
  `- L0 System landscape (start here)\n- L1 Subsystem architecture (one per bounded context)\n` +
  `- L2 Deep dives (important/interesting mechanisms)\n- Cross-cutting (data model, deployment, feature flags)\n\n` +
  `NEW docs produced in this set (level | file | title | scope):\n${fileList}\n\n` +
  `ALSO list and integrate the PRE-EXISTING docs that were kept (read the directory to confirm they exist): ` +
  `realtime-chat.md, threads-and-reactions.md, notifications.md, chat-domain-as-is-to-be.md. Place them at the right zoom level ` +
  `(realtime-chat=L2-ish flow, threads-and-reactions=L2, notifications=L1, chat-domain=design proposal).\n` +
  `Group docs by zoom level with a one-line description and relative link each. Add a "Related Design Docs" section pointing to ` +
  `docs/feature/*/design/, docs/runbooks/, docs/rca/, docs/design/, and docs/engineering-principles.md. Keep a short Scope Guide. ` +
  `Only write ${DIR}/README.md; modify no other file.`,
  { label: 'write:README.md', phase: 'Index' }
)

const critic = await agent(
  `Completeness audit for the Slackex architecture doc set at ${DIR}.\n` +
  `List every bounded context directory under ${ROOT}/lib/slackex/ (and the web tier under lib/slackex_web/). ` +
  `Then read ${DIR}/README.md and the file list to determine which contexts/features now have architecture-doc coverage and which do NOT.\n` +
  `Report covered contexts, genuine gaps (a context or notable feature with no doc), and concrete suggestions for any gaps.\n` +
  `Do NOT modify any files.`,
  { label: 'critic:completeness', phase: 'Index', agentType: 'Explore', schema: CRITIC_SCHEMA }
)

return {
  docsWritten: results.length,
  inaccurate: results.filter(r => r && !r.accurate).map(r => r.file),
  missingMermaid: results.filter(r => r && !r.hasMermaid).map(r => r.file),
  totalIssuesFixed: results.reduce((n, r) => n + (r?.fixesApplied?.length || 0), 0),
  completeness: critic,
}
