// Mock data for the Tenun prototype.

const USERS = {
  dave: { id: 'dave', name: 'davewil1973', initial: 'D', color: '#e8c547', status: 'Vibing' },
  efdp: { id: 'efdp', name: 'efdp', initial: 'E', color: '#7c5cff', status: 'Heads down' },
  claude: { id: 'claude', name: 'Claude', initial: 'C', color: '#d97757', status: 'thinking…', bot: true },
  keem: { id: 'keem', name: 'cmdr_keem', initial: 'K', color: '#3ecf8e', status: 'On call' },
  mina: { id: 'mina', name: 'mina.lin', initial: 'M', color: '#ff8fbf', status: 'Afk · back at 14:00' },
  jules: { id: 'jules', name: 'jules', initial: 'J', color: '#7fb5ff', status: '' },
  riko: { id: 'riko', name: 'riko', initial: 'R', color: '#c9a93b', status: '' },
  davewil2: { id: 'davewil2', name: 'davewil2', initial: 'D', color: '#7c5cff', status: '' },
};

const CHANNELS = [
  { id: 'deploys',     name: 'deploys',     activity: 0.92, unread: 3,  topic: 'shipping & rollbacks · ping @oncall for emergencies' },
  { id: 'golf',        name: 'golf-product', activity: 0.6, unread: 0 },
  { id: 'mobsters',    name: 'mobsters',    activity: 0.3, unread: 0 },
  { id: 'slackex',     name: 'slackex-feature-requests', activity: 0.45, unread: 1 },
  { id: 'bugs',        name: 'tenun-bugs-annoyances', activity: 0.7, unread: 0 },
  { id: 'test',        name: 'test',        activity: 0.1, unread: 0 },
  { id: 'welcome',     name: 'welcome',     activity: 0.2, unread: 0 },
];

const DMS = [
  { id: 'efdp',     user: 'efdp',     presence: 'away' },
  { id: 'claude',   user: 'claude',   presence: 'online' },
  { id: 'keem',     user: 'keem',     presence: 'online' },
  { id: 'davewil2', user: 'davewil2', presence: 'offline' },
];

// Channel: #deploys — a realistic deploy conversation with code, links, reactions, a thread.
const MESSAGES = [
  {
    id: 'm-divider-1',
    type: 'day',
    label: 'Today · Tuesday, May 26',
  },
  {
    id: 'm1',
    user: 'keem',
    time: '09:42',
    body: [
      { type: 'text', value: "morning — kicking off the **v2.41** train. blockers? speak now or hold the loom." },
    ],
    reactions: [{ emoji: '🧵', count: 4, mine: false }, { emoji: '🚀', count: 3, mine: true }],
  },
  {
    id: 'm2',
    user: 'mina',
    time: '09:44',
    body: [
      { type: 'text', value: "nothing on my side. embeddings backfill finished overnight — we're at 100% coverage on `messages` and `threads`." },
      { type: 'callout', tone: 'ok', icon: '◇', text: 'pgvector backfill · 14.2M rows · 6h 12m · 0 retries' },
    ],
  },
  {
    id: 'm3',
    user: 'efdp',
    time: '09:47',
    body: [
      { type: 'text', value: "🎉 — i'll re-enable semantic search in the composer behind the `:semantic_search` flag once we're green." },
    ],
    reactions: [{ emoji: '🎉', count: 5, mine: true }, { emoji: '🧶', count: 2, mine: false }],
  },
  {
    id: 'm4',
    user: 'jules',
    time: '09:52',
    body: [
      { type: 'text', value: "small follow-up from yesterday — the channel summariser was timing out on >2k messages. fix is a streaming chunked map-reduce. PR up:" },
      { type: 'code', lang: 'elixir', value: `defmodule Tenun.AI.Summary do
  @chunk 256

  def summarize(channel_id, opts \\\\ []) do
    channel_id
    |> Messages.stream_window(opts[:since])
    |> Stream.chunk_every(@chunk)
    |> Task.async_stream(&map_chunk/1, max_concurrency: 4)
    |> Enum.reduce(%Acc{}, &reduce/2)
    |> finalize()
  end
end` },
      { type: 'unfurl', site: 'GitHub', title: 'tenun/tenun#1842 — Chunked map-reduce summariser', subtitle: 'Streams channel windows in 256-message chunks; bounded concurrency; preserves source ranges for citations.', meta: ['+247 −38', '3 files', 'jules → main'] },
    ],
    reactions: [{ emoji: '🔥', count: 7, mine: true }, { emoji: '👀', count: 2 }, { emoji: '🧵', count: 1 }],
    threadCount: 6,
    threadUsers: ['keem', 'mina', 'claude'],
    threadLastTime: '11:38',
  },
  {
    id: 'm5',
    user: 'dave',
    time: '10:04',
    body: [
      { type: 'text', value: "small UX nit while we're here — when summary is loading, can we show the loom animation instead of the spinner? feels more on-brand." },
    ],
    reactions: [{ emoji: '🧶', count: 4, mine: false }],
  },
  {
    id: 'm6',
    user: 'claude',
    time: '10:06',
    isBot: true,
    body: [
      { type: 'ai-context', value: 'replying to dave · drafted via /assist' },
      { type: 'text', value: "I can wire that up. The current spinner is in `LiveTenun.Components.Loader` — swapping it for the warp/weft SVG is a 4-line change. Want me to open a PR?" },
    ],
  },
  {
    id: 'm-divider-2',
    type: 'unread',
    label: '3 new messages · Mina, jules, riko',
  },
  {
    id: 'm7',
    user: 'riko',
    time: '11:21',
    body: [
      { type: 'text', value: "rolling out **v2.41** to `staging` now. will keep an eye on p99 latency on `embeddings.search`." },
    ],
  },
  {
    id: 'm8',
    user: 'mina',
    time: '11:33',
    body: [
      { type: 'text', value: "while we wait — i drafted the markdown reference for the help docs. feedback welcome:" },
      { type: 'markdown-demo' },
    ],
    reactions: [{ emoji: '📝', count: 3 }, { emoji: '💛', count: 2, mine: true }],
  },
  {
    id: 'm9',
    user: 'jules',
    time: '11:46',
    body: [
      { type: 'text', value: "staging green ✓ — moving to canary (5%) at the top of the hour." },
      { type: 'metrics' },
    ],
  },
];

// Thread for m4 (Jules' PR)
const THREAD_MESSAGES = [
  {
    id: 't1',
    user: 'keem',
    time: '09:58',
    body: [{ type: 'text', value: "nice. how are you bounding the prompt — do we cap tokens per chunk before reduce?" }],
  },
  {
    id: 't2',
    user: 'jules',
    time: '10:02',
    body: [{ type: 'text', value: "yep — `@chunk` is 256 msgs but each chunk goes through `Tokenizer.trim/2` to land under 3k input tokens. reduce step uses a smaller cap (1.5k) since we're summarising summaries." }],
    reactions: [{ emoji: '👍', count: 2, mine: true }],
  },
  {
    id: 't3',
    user: 'mina',
    time: '10:24',
    body: [{ type: 'text', value: "do we preserve source ranges so the UI can cite back to individual messages? would love to keep the 'jump to source' affordance." }],
  },
  {
    id: 't4',
    user: 'jules',
    time: '10:31',
    body: [{ type: 'text', value: "yes — each summary point carries a `{from_id, to_id}` tuple. the LiveView will get a `phx-click` that scrolls back to the warp." }],
  },
  {
    id: 't5',
    user: 'claude',
    time: '10:34',
    isBot: true,
    body: [
      { type: 'ai-context', value: 'observation' },
      { type: 'text', value: "Worth noting: if a summary point spans a thread boundary, the citation should expand to include the parent message. Otherwise users land on a reply with no context." },
    ],
  },
  {
    id: 't6',
    user: 'jules',
    time: '11:38',
    body: [{ type: 'text', value: "good catch — added that to the PR. will land before canary." }],
  },
];

// AI summarize output for #deploys
const SUMMARY = {
  channel: 'deploys',
  range: '9:42 AM — 11:46 AM · 9 messages · 4 people · 1 active thread',
  threads: [
    {
      title: 'v2.41 release train',
      strands: ['keem', 'mina', 'efdp', 'riko'],
      points: [
        { text: 'Release v2.41 is unblocked. The pgvector embeddings backfill finished overnight at 100% coverage across messages and threads.', src: ['m1', 'm2'] },
        { text: 'Semantic search will be re-enabled in the composer behind the :semantic_search flag once the release is green.', src: ['m3'] },
        { text: 'Riko has rolled out v2.41 to staging; canary (5%) is queued for the top of the hour.', src: ['m7', 'm9'] },
      ],
    },
    {
      title: 'Chunked summariser PR (#1842)',
      strands: ['jules', 'keem', 'mina', 'claude'],
      points: [
        { text: 'Jules opened a PR fixing the channel summariser timeout on long histories using a streaming chunked map-reduce (256 msgs per chunk, bounded concurrency).', src: ['m4'] },
        { text: 'Each chunk is trimmed under 3k input tokens; the reduce step caps at 1.5k. Source ranges are preserved per summary point for citations.', src: ['t2', 't4'] },
        { text: 'Claude flagged that thread-boundary spans should expand citations to include parent context — fix added before canary.', src: ['t5', 't6'] },
      ],
    },
    {
      title: 'Loom loading animation',
      strands: ['dave', 'claude'],
      points: [
        { text: 'Dave requested swapping the summary spinner for the on-brand loom animation; Claude offered to open a 4-line PR against LiveTenun.Components.Loader.', src: ['m5', 'm6'] },
      ],
    },
  ],
  followups: [
    'Decide who owns the loom-loader PR (Claude offered, dave to confirm).',
    'Confirm canary scope and rollback criteria with riko before noon.',
    'Mina to circulate the markdown reference for help-docs review.',
  ],
};

// ─────────────────────────── Team workflow surfaces ───────────────────────────

// "On the Loom" — ambient live status strip pinned to #deploys
const ON_THE_LOOM = {
  trunk: {
    sha: 'a7f2e1c',
    branch: 'main',
    author: 'jules',
    title: 'fix(summariser): chunked map-reduce with source ranges',
    status: 'deploying',           // building | deploying | live | failed
    progress: 0.68,                // 0..1
    stage: 'canary 5% · soaking',
    eta: '~6m',
  },
  oncall: {
    primary: 'riko',
    secondary: 'keem',
    until: 'Fri 17:00',
  },
  flags: [
    { name: ':semantic_search', state: 'on',  rollout: 1.00, owner: 'efdp' },
    { name: ':loom_v2',         state: 'canary', rollout: 0.05, owner: 'mina' },
    { name: ':emoji_picker_v3', state: 'off', rollout: 0.00, owner: 'dave' },
  ],
  pagers: 0,
};

// Customers referenced in this channel via &Customer chips
const CUSTOMERS = {
  acme: {
    id: 'acme',
    name: 'Acme Looms',
    tier: 'Enterprise',
    arr: '$184k',
    arrN: 184000,
    health: 'healthy',
    csm: 'mina',
    recent: '2 reports · last: search latency spikes (resolved)',
    contacts: [{ name: 'Priya Ramanan', role: 'VP Eng' }],
    contractEnd: 'Feb 14 · 2026',
    daysOut: 263,
    renewalProb: 'high',
    expansionPotential: '+$52k',
    lastTouch: 'May 24 · CSM call',
    nextTouch: 'Thu · QBR',
    trend7d: 'up',
  },
  northbay: {
    id: 'northbay',
    name: 'Northbay Co-op',
    tier: 'Growth',
    arr: '$28k',
    arrN: 28000,
    health: 'at-risk',
    csm: 'mina',
    recent: '5 reports · last: thread summary truncation',
    contacts: [{ name: 'Hannah Ito', role: 'Ops Lead' }, { name: 'Sam Park', role: 'Tech Lead' }],
    renewalIn: '9d',
    contractEnd: 'Jun 05',
    daysOut: 9,
    renewalProb: 'at-risk',
    expansionPotential: '\u2014',
    lastTouch: 'May 26 · risk call',
    nextTouch: 'Today 14:00 · follow-up',
    trend7d: 'down',
  },
  loomwork: {
    id: 'loomwork',
    name: 'Loomwork',
    tier: 'Growth',
    arr: '$54k',
    arrN: 54000,
    health: 'healthy',
    csm: 'mina',
    recent: '3 conversations · feedback-rich',
    contacts: [{ name: 'Marcus Vela', role: 'Eng Director' }],
    contractEnd: 'Nov 22',
    daysOut: 179,
    renewalProb: 'high',
    expansionPotential: '+$18k',
    lastTouch: 'May 23 · sales call',
    nextTouch: 'Wed · check-in',
    trend7d: 'flat',
  },
};

// PR detail (live CI checks) used in the rich unfurl
const PR_1842 = {
  repo: 'tenun/tenun',
  number: 1842,
  title: 'Chunked map-reduce summariser',
  author: 'jules',
  branch: 'jules/chunked-summary → main',
  state: 'open · ready to merge',
  diff: { plus: 247, minus: 38, files: 3 },
  reviewers: [
    { user: 'keem', state: 'approved' },
    { user: 'mina', state: 'approved' },
    { user: 'efdp', state: 'commented' },
  ],
  checks: [
    { name: 'ci · mix test',          state: 'pass', time: '3m 12s' },
    { name: 'ci · credo',             state: 'pass', time: '14s' },
    { name: 'ci · dialyzer',          state: 'pass', time: '2m 04s' },
    { name: 'preview · staging',      state: 'pass', time: 'live' },
    { name: 'preview · summariser',   state: 'soak', time: '6m 22s' },
    { name: 'ci · pgvector migration', state: 'pass', time: '41s' },
  ],
};

// Weekly Spool — the Loom scoped to a week, grouped by person
const WEEKLY_SPOOL = {
  range: 'May 19 — May 26 · across #deploys, #tenun-bugs-annoyances, #golf-product',
  people: [
    {
      user: 'jules',
      headline: 'Landed the chunked summariser',
      points: [
        'Shipped #1842 (chunked map-reduce) — channel summarisation now bounded under 4s on 10k-message histories.',
        'Picked up the loom-loader swap from dave; PR open against LiveTenun.Components.Loader.',
      ],
      shipped: 2, reviewing: 4,
    },
    {
      user: 'mina',
      headline: 'Embeddings backfill + customer triage',
      points: [
        'Completed 14.2M-row pgvector backfill across messages and threads (0 retries).',
        'Triaged Northbay summary-truncation report — root cause filed as #1849.',
      ],
      shipped: 1, reviewing: 3,
    },
    {
      user: 'efdp',
      headline: 'Re-enabling semantic search',
      points: [
        'Flipped :semantic_search to 100% in the composer once embeddings hit full coverage.',
        'Wired the echo-dedup hint into the composer behind :loom_v2.',
      ],
      shipped: 3, reviewing: 2,
    },
    {
      user: 'keem',
      headline: 'Release wrangling',
      points: [
        'Drove the v2.41 train; one rollback (auth migration) cleanly recovered in 4m.',
        'Refactored Tenun.Releases to expose canary progress for ambient strip.',
      ],
      shipped: 4, reviewing: 6,
    },
  ],
  decisions: [
    { title: 'Default `:loom_v2` to 5% canary for one week', dri: 'mina', date: 'May 23' },
    { title: 'Adopt chunked map-reduce as the default summariser', dri: 'jules', date: 'May 26' },
  ],
  customers: ['acme', 'northbay'],
};

// Inject extra realism into the message list: add the On-the-Loom strip,
// a Decision card, a Customer-voice mention, an Oncall handoff, and an Echo
// hint — by extending the bodies of existing messages and adding new ones.

// Mutate jules' PR message to use the rich PR unfurl
const julesMsg = MESSAGES.find((m) => m.id === 'm4');
if (julesMsg) {
  julesMsg.body = [
    { type: 'text', value: "small follow-up from yesterday — the channel summariser was timing out on >2k messages. fix is a streaming chunked map-reduce. PR up:" },
    { type: 'code', lang: 'elixir', value: `defmodule Tenun.AI.Summary do
  @chunk 256

  def summarize(channel_id, opts \\\\ []) do
    channel_id
    |> Messages.stream_window(opts[:since])
    |> Stream.chunk_every(@chunk)
    |> Task.async_stream(&map_chunk/1, max_concurrency: 4)
    |> Enum.reduce(%Acc{}, &reduce/2)
    |> finalize()
  end
end` },
    { type: 'pr', pr: 'PR_1842' },
  ];
}

// Insert new messages: oncall handoff (early), decision card mid, customer
// voice unfurl, and a "/decide" command result.
const extraMessages = [
  // oncall handoff — riko taking the pager from keem
  {
    id: 'm0a',
    user: 'keem',
    time: '09:40',
    body: [
      { type: 'oncall-handoff', from: 'keem', to: 'riko', until: 'Fri 17:00', notes: [
        'embeddings backfill running — should finish before 10:00',
        'watch p99 on `embeddings.search` after v2.41 canary',
        'Northbay (Northbay Co-op) flagged a summary-truncation issue — Mina has it',
      ]},
    ],
    reactions: [{ emoji: '🫡', count: 4, mine: true }],
  },
  // decision card — captured from /decide in a side thread
  {
    id: 'm6a',
    user: 'mina',
    time: '10:48',
    body: [
      { type: 'text', value: "spinning the spool earlier — capturing where we landed:" },
      { type: 'decision',
        title: 'Default `:loom_v2` to 5% canary for one week',
        dri: 'mina',
        stakeholders: ['jules', 'efdp', 'dave'],
        date: 'May 26 · 10:46',
        what: 'Roll `:loom_v2` to 5% of workspaces; gather satisfaction + latency for 7 days before any expansion.',
        why: 'Summarisation quality looks good in eval, but we want real-team signal before raising the wager.',
        next: [
          { who: 'mina', what: 'Pin a Spool query to track p95 latency + thumbs-up rate' },
          { who: 'jules', what: 'Add `loom.canary.satisfaction` to the dashboard' },
          { who: 'efdp', what: 'Schedule a check-in for Jun 2' },
        ],
        sources: ['t3', 't4'],
      },
    ],
    reactions: [{ emoji: '✅', count: 5, mine: true }, { emoji: '🧶', count: 2 }],
  },
  // customer voice — dave loops a customer report into the channel
  {
    id: 'm8a',
    user: 'dave',
    time: '11:35',
    body: [
      { type: 'text', value: "while we're polishing — &northbay flagged something this morning that might be related to the new summariser. cc &acme who reported a near-identical thing last week (now resolved)." },
      { type: 'customer-row', customers: ['northbay', 'acme'] },
    ],
  },
];

// Splice them in at sensible positions, keeping the divider order:
function spliceMessages(base, additions) {
  const out = [...base];
  for (const m of additions) {
    if (m.id === 'm0a') {
      // place right after the day divider
      const i = out.findIndex((x) => x.id === 'm-divider-1');
      out.splice(i + 1, 0, m);
    } else if (m.id === 'm6a') {
      const i = out.findIndex((x) => x.id === 'm6');
      out.splice(i + 1, 0, m);
    } else if (m.id === 'm8a') {
      const i = out.findIndex((x) => x.id === 'm8');
      out.splice(i + 1, 0, m);
    }
  }
  return out;
}

const FINAL_MESSAGES = spliceMessages(MESSAGES, extraMessages);

// ─────────────────────────── The Tapestry ───────────────────────────
// Where the Loom summarises a channel, the Tapestry is the chef walking
// the pass — leadership-grade drop-in across the whole organisation.
// Same underlying weave, different scale.

const VIEWERS = {
  ceo: { id: 'ceo', name: 'Andre Wirjawan', role: 'CEO', initial: 'A', color: '#d97757', focus: ['customers','decisions','risks','wins'], surface: 'tapestry' },
  cto: { id: 'cto', name: 'Petra Sjögren',  role: 'CTO', initial: 'P', color: '#7c5cff', focus: ['shipping','risks','decisions','pulse'], surface: 'tapestry' },
  em:  { id: 'em',  name: 'Cmdr Keem',      role: 'EM',  initial: 'K', color: '#3ecf8e', focus: ['pulse','decisions','blockers'], surface: 'tapestry' },
  keem:{ id: 'keem',name: 'cmdr_keem',      role: 'Arch',initial: 'K', color: '#3ecf8e', focus: ['stack','horizon','bench'], surface: 'stack' },
  efdp:{ id: 'efdp',name: 'efdp',           role: 'Staff', initial: 'E', color: '#7c5cff', focus: ['distill','package','tension'], surface: 'reduction' },
  dave:{ id: 'dave',name: 'davewil1973',    role: 'PO',    initial: 'D', color: '#d97757', focus: ['voice','shape','customers'], surface: 'expo' },
  mina:{ id: 'mina',name: 'mina.lin',       role: 'CSM',   initial: 'M', color: '#ff8fbf', focus: ['health','moments','calls','renewals'], surface: 'floor' },
};

const TAPESTRY_DATA = {
  since: '4d 6h ago · Friday, May 22 · 16:24',
  cadence: { shipped: 23, prsMerged: 41, decisions: 6, incidents: 1, mttr: '14m' },

  marquee: {
    kind: 'milestone',
    title: 'The new chunked summariser shipped on trunk',
    body: 'Channel summarisation is now bounded under 4s on 10k-message histories. Customer-visible, behind `:loom_v2` (5% canary). Two enterprise customers were waiting on this.',
    owner: 'jules',
    impact: ['Northbay Co-op blocker · resolved', 'Acme Looms expansion · unblocked'],
    src: ['m4', 'm6a'],
  },

  customers: {
    healthMove: { healthier: 3, atRisk: 1, churn: 0 },
    expansion: [
      { name: 'Acme Looms', arr: '$184k', delta: '+$52k', signal: 'Loom v2 cited in renewal call · CSM mina' },
    ],
    atRisk: [
      { name: 'Northbay Co-op', arr: '$28k', signal: 'Summary truncation; 5 reports this week. Eng has it.', csm: 'dave' },
    ],
    quote: {
      text: 'Honestly, the Loom is the first AI summary I have ever trusted enough to forward to my board.',
      who: 'VP Eng · Acme Looms',
      via: 'CSM call · May 24',
    },
  },

  wins: [
    { title: 'Chunked summariser shipped', owner: 'jules', meta: 'PR #1842 · merged Mon · canary 5%' },
    { title: 'pgvector backfill complete', owner: 'mina', meta: '14.2M rows · 0 retries · embeddings at 100% coverage' },
    { title: 'Semantic search re-enabled in composer', owner: 'efdp', meta: 'flag `:semantic_search` at 100%' },
    { title: 'Release cadence held: 4 trains, 1 rollback', owner: 'keem', meta: 'MTTR 4m · zero customer-visible incidents' },
  ],

  decisions: {
    made: [
      { title: 'Default :loom_v2 to 5% canary for one week', dri: 'mina', date: 'May 26', tag: 'product' },
      { title: 'Adopt chunked map-reduce as the default summariser', dri: 'jules', date: 'May 26', tag: 'arch' },
      { title: 'Move :emoji_picker_v3 to Q3', dri: 'dave', date: 'May 24', tag: 'scope' },
    ],
    pendingYou: [
      { title: 'Hire backfill: Senior Eng (Search & Retrieval)', from: 'keem', need: 'sign-off on level + budget', age: '2d' },
      { title: 'Pricing tier rename: Growth → Studio', from: 'mina', need: 'go / no-go for Jun 10 launch', age: '6h' },
    ],
  },

  pulse: {
    teams: [
      { name: 'Search & AI', people: ['mina','efdp','jules'], shipping: 7, blocked: 0, note: 'Shipping heavy. Two flags hot.' },
      { name: 'Platform',    people: ['keem','riko'],         shipping: 4, blocked: 1, note: 'Riko blocked on infra (DB upgrade window).' },
      { name: 'Product',     people: ['dave'],                shipping: 2, blocked: 0, note: 'Dave running customer interviews this week.' },
    ],
    voices: [
      { user: 'mina',  note: 'positive · "best embedding work I have done"', tone: 'up' },
      { user: 'riko',  note: 'frustrated · waiting on DB infra', tone: 'down' },
      { user: 'jules', note: 'steady · in flow', tone: 'flat' },
    ],
  },

  risks: [
    { level: 'high',   title: 'Northbay renewal in 9 days, open complaint',
      why: 'Summary-truncation has been their #1 ask. Mina has fix in eng-review.' },
    { level: 'medium', title: 'Single-owner risk on summariser',
      why: 'Jules is sole reviewer for AI codepath. CTO suggests pairing efdp.' },
    { level: 'low',    title: 'Embedding compute cost +18% MoM',
      why: 'Within budget but trending. Worth a check before raising :loom_v2 above canary.' },
  ],

  dropIn: [
    { channel: '#tenun-bugs-annoyances', read: 'Three customer-reported issues, all triaged. Northbay one is the spicy one.', activity: 'warm' },
    { channel: '#golf-product',          read: 'Pricing-rename discussion is converging. Dave wants your read by Wed.', activity: 'hot' },
    { channel: 'dm with mina',           read: 'Mina flagged she wants 30 min before the board read-out.', activity: 'cool' },
  ],
};

// ─────────────────────────── The Reduction · efdp's workbench ───────────────
// Reduction = boiling stock down to its essence. efdp distills team chatter
// into packaged ideas every level of seniority can pick up cleanly.

// Lens IDs map to audiences they primarily serve:
//   principle → everyone   (jr · sr · pr · po · sme)
//   shape     → po · sme · jr
//   mechanism → sr · pr
//   edges     → pr · sme
//   ask       → team

const LENS_DEFS = [
  { id: 'principle', label: 'Principle', symbol: '◇', audience: ['everyone'] },
  { id: 'shape',     label: 'Shape',     symbol: '◐', audience: ['po','sme','jr'] },
  { id: 'mechanism', label: 'Mechanism', symbol: '◉', audience: ['sr','pr'] },
  { id: 'edges',     label: 'Edges',     symbol: '◍', audience: ['pr','sme'] },
  { id: 'ask',       label: 'Ask',       symbol: '◌', audience: ['team'] },
];

const REDUCTION_DATA = {
  user: 'efdp',
  today: {
    title: 'What does \u201Csemantic stewardship\u201D mean for Sous?',
    eyebrow: 'today\u2019s pattern · still drawing',
    raw: { messages: 14, threads: 3, customers: 2, claude: 1, channels: ['#deploys','#tenun-bugs-annoyances','#golf-product'] },
    state: 'drafting',
    note: 'Claude\u2019s observation about citation expansion across thread boundaries (m_t5) is the splinter that opened this whole thread for me. The question isn\u2019t \u201Cdo we cite\u201D, it\u2019s \u201Cwho owns the truthfulness of what gets cited.\u201D',
    lenses: {
      principle: { text: 'When we lift quotes from chat into AI surfaces, we take on stewardship for their context, accuracy, and freshness \u2014 the same way an editor stewards a source.', state: 'firm' },
      shape:     { text: 'Three editorial signals on every cited message: fresh / stale / contested. Surfaces (Loom, Tapestry, Echo) honour those signals before re-citing.', state: 'firm' },
      mechanism: { text: 'A `citation_state` projection backed by (a) embedding distance to current channel context, (b) explicit contest reactions, (c) staleness based on referenced facts. Cheap to read; recomputed on parent edit.', state: 'sketched' },
      edges:     { text: 'Cross-channel ACLs survive citation (must); private DMs never cite outward (must); contested doesn\u2019t mean wrong, it means \u201Cdon\u2019t resurface without a human\u201D.', state: 'sketched' },
      ask:       { text: 'Do we ever auto-retire a citation, or only ever flag and let a human decide? My instinct: flag, never retire.', state: 'open' },
    },
  },

  // Currently in the pot — ideas at various distillation stages.
  potIdeas: [
    {
      id: 'echo',
      title: 'Echo dedup',
      stage: 'packaged',
      domain: 'composer',
      pickup: { shape: 'jr', mechanism: 'sr', edges: 'pr' },
      lenses: {
        principle: { text: 'Surface prior answers before someone restates a known question \u2014 once, dismissable, never blocking.', state: 'firm' },
        shape:     { text: 'A single-line strip above the composer with up to two cited matches. One click to jump, X to dismiss for the channel.', state: 'firm' },
        mechanism: { text: 'Debounced (800ms) embedding search scoped to channel\u2218workspace, threshold 0.82, cap 3 results, rate-limited 1/req.', state: 'firm' },
        edges:     { text: 'Privacy: scope must respect channel ACLs. Cold-start: degrade silently. Drift: a wrong-but-confident match teaches the wrong thing \u2014 see Citation Stewardship.', state: 'firm' },
        ask:       { text: 'Should dismissal be per-question or per-channel? I am leaning per-question with a 30d memory.', state: 'open' },
      },
    },
    {
      id: 'loom-cite',
      title: 'Loom citation expansion',
      stage: 'distilling',
      domain: 'loom',
      pickup: { shape: 'sr', mechanism: 'sr', edges: 'pr' },
      lenses: {
        principle: { text: 'A summary point that points at a reply must also point at the parent it makes sense within. Otherwise we ship orphans.', state: 'firm' },
        shape:     { text: 'On click, the citation chip expands to show parent + reply together, lightly. No new view, no modal.', state: 'firm' },
        mechanism: { text: 'Walk one ancestor up the reply tree; if the parent is in-summary, render in place; else render as breadcrumb.', state: 'sketched' },
        edges:     { text: 'Threads can be deep. Cap at 2 ancestors. Beyond that, render a \u201C\u2026 4 messages above\u201D scroll-to link.', state: 'sketched' },
        ask:       { text: 'Do we treat \u201Ccite parent\u201D as a feature flag or default-on? Jules and I disagree.', state: 'open' },
      },
    },
    {
      id: 'stale',
      title: 'Stale embedding signal',
      stage: 'raw',
      domain: 'platform',
      pickup: { shape: 'pr', mechanism: 'pr' },
      lenses: {
        principle: { text: 'Embeddings drift. The system should know what it no longer knows.', state: 'firm' },
        shape:     { text: '\u2014 not yet drawn \u2014', state: 'open' },
        mechanism: { text: '\u2014 not yet drawn \u2014', state: 'open' },
        edges:     { text: 'Re-embedding is expensive. Silent re-embed risks divergence; loud re-embed risks alarm fatigue.', state: 'sketched' },
        ask:       { text: 'Is there a cheap freshness proxy (e.g. parent-message edits) we can rely on instead of recomputation?', state: 'open' },
      },
    },
    {
      id: 'decide',
      title: 'Decision auto-capture',
      stage: 'packaged',
      domain: 'ai',
      pickup: { shape: 'po', mechanism: 'sr', edges: 'pr' },
      lenses: {
        principle: { text: 'Decisions made in chat should be capturable in one motion, with their context, by the person making them.', state: 'firm' },
        shape:     { text: '`/decide` opens a 3-field card: What / Why / Next. Stakeholders pre-filled from the thread.', state: 'firm' },
        mechanism: { text: 'Slash-command opens a LiveView modal; on submit, posts a `decision` message + persists to `decisions` table indexed for Tapestry.', state: 'firm' },
        edges:     { text: 'Edit window 24h then locked. Stakeholders can append followups but not rewrite the decision itself.', state: 'firm' },
        ask:       { text: 'Where does the decision render in the Loom \u2014 inline at the moment, or pinned at top of summary?', state: 'open' },
      },
    },
  ],

  // Tensions efdp has noticed but not yet resolved \u2014 the part of the work
  // that is hardest because it asks a question, not gives an answer.
  tensions: [
    {
      title: 'Echo is helpful for known answers, hostile to new framings.',
      why: 'A novel rephrasing of an old idea still embeds close to the original. We can suppress the spark we are trying to encourage. Possible answer: bias toward newer messages in the dedup score.',
      weight: 'high',
      related: ['echo'],
    },
    {
      title: 'Citations want to expand, summaries want to compress.',
      why: 'The Loom\u2019s job is to be short. Stewardship asks for more context. We will need a citation interaction model that hides the expansion behind a single tap so the summary stays clean.',
      weight: 'med',
      related: ['loom-cite'],
    },
    {
      title: 'If a flag is on for 5% of workspaces, whose week is that?',
      why: 'Mina has :loom_v2 at canary. If it misbehaves at 03:00, the oncall (Riko) gets paged. We have no contract for \u201Cfeature owner accepts off-hours alerts on canary features.\u201D',
      weight: 'med',
      related: [],
    },
  ],

  // Carried = packaged and now owned by someone else.
  carried: [
    { title: 'Chunked summariser', owner: 'jules', state: 'shipped · canary 5%', since: '2d' },
    { title: 'pgvector backfill',  owner: 'mina',  state: 'complete · monitoring drift', since: '4d' },
    { title: 'Loom loader (loom animation)', owner: 'claude', state: 'PR open', since: '3h' },
    { title: 'Semantic search re-enable', owner: 'efdp', state: 'rolled to 100%', since: '6h', mine: true },
  ],
};

window.TENUN_LENS_DEFS = LENS_DEFS;

// ─────────────────────────── The Stack · cmdr_keem's perch ─────────────────
// keem is the cartographer + perimeter watcher. He maps Tenun's dependencies
// and tracks every release in the ecosystem that touches them, with his own
// "should we act?" verdict attached. He reads RFCs in his spare time.

const STACK_DATA = {
  user: 'keem',
  asOf: 'May 27, 06:14 · 41 sources polled · pollers green',

  // What changed in the world this week × what we run × keem's read.
  horizon: [
    {
      what: 'Phoenix LiveView 1.0.0-rc.7',
      where: 'phoenixframework/phoenix_live_view',
      when: '4d',
      ours: 'we run 0.20.17',
      impact: 'API freeze · async assigns · streams overhaul',
      severity: 'critical',
      keems: 'This is the big one. Streams alone will drop ~200 LOC from our message-list virtualization. I\u2019m drafting the upgrade RFC by Thursday \u2014 efdp pls review.',
      tags: ['liveview','runtime'],
    },
    {
      what: 'claude-haiku-4-5 released',
      where: 'anthropic',
      when: '12h',
      ours: 'we use haiku-3-5 for the Loom',
      impact: '~2.4x faster · improved long-context recall',
      severity: 'opportunity',
      keems: 'Bench on chunked-summary fixtures by EOD. If RAGAS holds, ship behind `:loom_v2` for canary cohort first.',
      tags: ['ai','models'],
    },
    {
      what: 'pgvector 0.8.0',
      where: 'pgvector/pgvector',
      when: '6h',
      ours: 'we run 0.7.4 on staging+prod',
      impact: 'HNSW build ~30% faster on bulk ingest',
      severity: 'opportunity',
      keems: 'Mina\u2019s nightly backfill could shave ~1.8h. Safe minor upgrade; I\u2019ll stage Wednesday.',
      tags: ['pg','embeddings'],
    },
    {
      what: 'Elixir 1.18.0-rc.1',
      where: 'elixir-lang/elixir',
      when: '2d',
      ours: 'we\u2019re on 1.17.2',
      impact: 'set-theoretic types now warn in more places · `Code.fetch_docs` faster',
      severity: 'watch',
      keems: 'Hold for the .0. Type-checker is loud on first run; we\u2019ll want a quiet hour.',
      tags: ['runtime'],
    },
    {
      what: 'pg_search 0.10 (native BM25 on Postgres)',
      where: 'paradedb/pg_search',
      when: '1d',
      ours: 'we run BM25 in app-layer Elixir',
      impact: 'BM25 + faceted search inside Postgres',
      severity: 'watch',
      keems: 'Tempting. Moves logic into DB \u2014 harder to test, harder to evict. Not now. Bookmarked.',
      tags: ['pg','search'],
    },
    {
      what: 'OTel Erlang/Phoenix 1.5.1',
      where: 'open-telemetry/opentelemetry-erlang-contrib',
      when: '3h',
      ours: 'we instrument with otel_phoenix 1.4',
      impact: 'fixes channel-span attribution',
      severity: 'trivia',
      keems: 'Patch in any quiet hour. No urgency.',
      tags: ['otel','obs'],
    },
    {
      what: 'Honeycomb \u2192 query-builder beta',
      where: 'honeycomb.io changelog',
      when: '2d',
      ours: 'we use Honeycomb classic',
      impact: 'derived columns + heatmaps on traces',
      severity: 'trivia',
      keems: 'Promising for incident review. I\u2019ll port one runbook over and see.',
      tags: ['obs'],
    },
  ],

  // The Stack — what Tenun is built on, layer by layer.
  layers: [
    { name: 'Runtime', items: [
      { tech: 'Elixir',     v: '1.17.2',   status: 'current', lastTouch: '2w' },
      { tech: 'Erlang/OTP', v: '27.1',     status: 'current', lastTouch: '6w' },
    ]},
    { name: 'Web', items: [
      { tech: 'Phoenix',  v: '1.7.18',  status: 'current', lastTouch: '3w' },
      { tech: 'LiveView', v: '0.20.17', status: 'lag', behind: '1.0-rc.7', lastTouch: '1w', concern: 'streams + async assigns waiting' },
      { tech: 'Tailwind', v: '3.4.14',  status: 'current', lastTouch: '4d' },
    ]},
    { name: 'Data', items: [
      { tech: 'Postgres', v: '16.2',   status: 'current', lastTouch: '1w' },
      { tech: 'pgvector', v: '0.7.4',  status: 'lag', behind: '0.8.0', lastTouch: '3d', concern: 'bulk-ingest perf win' },
      { tech: 'Ecto',     v: '3.12.4', status: 'current', lastTouch: '2w' },
    ]},
    { name: 'AI', items: [
      { tech: 'Claude haiku', v: '3-5',   status: 'lag', behind: '4-5', lastTouch: '6w', concern: 'eval pending; 2.4x speed claim' },
      { tech: 'tiktoken_ex',  v: '0.7.1', status: 'current', lastTouch: '5w' },
    ]},
    { name: 'Observability', items: [
      { tech: 'OpenTelemetry', v: '1.4',  status: 'lag', behind: '1.5.1', lastTouch: '8w', concern: 'channel-span fix' },
      { tech: 'Honeycomb',     v: '\u2014',     status: 'current', lastTouch: '\u2014', kind: 'service' },
    ]},
  ],

  // Library — keem's reading list with his own marginalia.
  library: [
    {
      kind: 'paper', title: 'RAGAS: Automated Eval for RAG', where: 'EMNLP 2024',
      note: 'Adopt `context_precision` + `faithfulness` as Loom eval signals. Wire into `/eval` before raising `:loom_v2`.',
      tag: 'eval',
    },
    {
      kind: 'rfc', title: 'LiveView 1.0 \u2014 streams + async assigns', where: 'phoenix_live_view#3245',
      note: 'Read 3x. Streams will let us drop our hand-rolled virtualization in `LiveTenun.MessageList`.',
      tag: 'liveview',
    },
    {
      kind: 'post', title: 'How Linear thinks about realtime conflicts', where: 'linear.app/blog',
      note: 'Useful for `/decide` \u2014 what happens when two people decide on the same thread within seconds.',
      tag: 'design',
    },
    {
      kind: 'paper', title: 'HNSW: efficient ANN search', where: 'Malkov & Yashunin · 2018',
      note: 'Re-read with pgvector 0.8 in mind. `m`/`ef_construction` worth revisiting once we upgrade.',
      tag: 'embeddings',
    },
    {
      kind: 'thread', title: '@joaquinpco · LLM context distillation patterns', where: 'twitter · 12d',
      note: '"compression-then-routing" framing is close to efdp\u2019s citation-stewardship reduction. Pass to efdp.',
      tag: 'ai',
    },
  ],

  // Bench — comparisons keem has actually run.
  bench: [
    { title: 'pgvector vs Qdrant vs Lance · 4w eval', when: 'Mar', verdict: 'pgvector won on ops simplicity. Within 8% of Qdrant on p95.', kept: true },
    { title: 'haiku-3-5 vs sonnet-3-5 on summary quality', when: 'May', verdict: 'sonnet +12% RAGAS faithfulness · 4.4x cost. Haiku acceptable for now.', kept: true },
    { title: 'Tailwind v4 alpha vs v3', when: 'Apr', verdict: 'CSS-first config nice but plugin story not ready. Hold.', kept: false },
  ],

  // Open questions keem is chewing on.
  chewing: [
    'Do we keep BM25 in Elixir or move to pg_search 0.10? (Custody vs performance.)',
    'Should we ship our own embedding model fine-tuned on chat? (Probably no, but I keep coming back to it.)',
    'How do we eval the Loom for "felt useful" vs RAGAS metrics? Need a thumb signal.',
    'OTel traces \u2192 Loom: can a slow summary surface its own slow span next to the citations?',
  ],
};

// ─────────────────────────── In Service · the brigade at work ─────────────
// Not a metrics dashboard. A unified view of every unit of work in flight —
// changes, decisions, ideas, fixes, incidents, hires — moving across kitchen
// states. Each work item shows a different one-line read per viewer; same
// atoms, different prisms. Production health is woven in where relevant, not
// quarantined to a separate page.

// Work states map to the kitchen line:
//   order   — called in, not yet started
//   mise    — prepped, in progress (drafts, branches, designs)
//   pass    — about to walk or live & being watched
//   walked  — shipped, off the line

const WORK_ITEMS = [
  // ─── On the Pass — about to walk or live and being watched ───
  {
    id: 'w-summariser',
    title: 'Chunked summariser',
    kind: 'change',
    state: 'pass',
    moved: '2h ago',
    heat: 'warm',
    people: { lead: 'jules', supporting: ['mina'], watching: ['riko'] },
    evidence: [
      { kind: 'pr', label: '#1842 · merged' },
      { kind: 'slo', label: 'embeddings.search · p99 watch' },
      { kind: 'flag', label: ':loom_v2 · canary 5%' },
    ],
    attention: { ceo: 'watch', cto: 'act',   em: 'watch', keem: 'watch', efdp: 'know'  },
    facets: {
      ceo: 'Live on canary. Unblocks Acme expansion and the Northbay summary issue. One-week soak before we raise.',
      cto: 'Merged. +18ms p99 on embeddings.search post-deploy \u2014 likely the tighter knn() inner loop. Rollback path is clean; we wait.',
      em:  'Jules\u2019 week-long work landed clean. Riko has the pager. Mina\u2019s citation work is unblocked downstream.',
      keem:'Inner knn() loop is now hotter per call but cheaper to amortise on chunks. Stats may be stale post-backfill \u2014 worth ANALYZE before raising canary.',
      efdp:'This is the substrate underneath citation stewardship. The chunk boundary is where parent/child citation has ground truth to point at.',
    },
    askFor: { cto: 'Decide if we raise canary or hold for ANALYZE.' },
  },
  {
    id: 'w-northbay',
    title: 'Northbay summary truncation fix',
    kind: 'fix',
    state: 'pass',
    moved: '4h ago',
    customer: 'northbay',
    people: { lead: 'mina', supporting: ['jules'] },
    evidence: [
      { kind: 'pr', label: '#1849 · in review' },
      { kind: 'customer', label: '&Northbay · 5 reports' },
    ],
    attention: { ceo: 'act',   cto: 'watch', em: 'watch', keem: 'know',  efdp: 'know'  },
    facets: {
      ceo: 'Customer #1 ask. Rolling out today. Renewal in 9 days \u2014 we want this seen before the call.',
      cto: 'Mina\u2019s fix in eng-review. Bound-check on Acc state; ships behind a flag for safety.',
      em:  'Mina paired with jules on the chunking edge case. Clean handoff, low friction.',
      keem:'Truncation happened mid-citation when a chunk ended on a thread boundary. Patch is small; defensive enough.',
      efdp:'The visible symptom of the citation-stewardship reduction. Useful evidence; will reference in the writeup.',
    },
    askFor: { ceo: 'Should we surface the fix to Northbay\u2019s CSM before the renewal call?' },
  },
  {
    id: 'w-p99',
    title: 'p99 elevated on embeddings.search',
    kind: 'incident',
    state: 'pass',
    moved: '6m ago',
    heat: 'hot',
    people: { lead: 'riko', supporting: ['jules'] },
    evidence: [
      { kind: 'runbook', label: 'embeddings.search elevated · suggested' },
      { kind: 'trace',   label: 'knn() span · 88% of p99' },
      { kind: 'slo',     label: 'budget · 34% · burning' },
    ],
    attention: { ceo: 'know', cto: 'watch', em: 'watch', keem: 'act',  efdp: 'know' },
    facets: {
      ceo: 'Watching. Not customer-visible. Burn rate inside SLO budget.',
      cto: 'Six minutes elevated, tracks the summariser merge. Runbook ready; not yet executed. Rollback is one button if we cross 15m or 250ms.',
      em:  'Riko on the pager, Jules nearby. No need to spin anyone up unless we cross thresholds.',
      keem:'knn() span is 88% of latency. ANALYZE on the embeddings index is the cheap next step; failing that, lower max_concurrency in the summariser.',
      efdp:'Worth a postmortem note even if it self-resolves: did chunking change query distribution into the index?',
    },
    askFor: { keem: 'Call ANALYZE now or wait for the next quiet window?' },
  },

  // ─── Mise — prepped, in progress ───
  {
    id: 'w-echo',
    title: 'Echo dedup behind :loom_v2',
    kind: 'change',
    state: 'mise',
    moved: '1d ago',
    people: { lead: 'efdp' },
    evidence: [
      { kind: 'pr', label: '#1851 · draft' },
      { kind: 'reduction', label: 'idea · packaged' },
    ],
    attention: { ceo: 'hidden', cto: 'know', em: 'know', keem: 'know', efdp: 'act' },
    facets: {
      ceo: 'Quality move. Less noise in channels that ask the same question twice.',
      cto: 'efdp\u2019s. Behind a flag from day one. Safe to land any time.',
      em:  'efdp working alone, in flow. Echo and citation work converge on the same projection.',
      keem:'800ms debounce, 0.82 threshold, channel-scoped. Hits the embedding index; caches well.',
      efdp:'Principle and Mechanism firm. Edges sketched (privacy + cold-start). Ask still open: per-question or per-channel dismissal.',
    },
  },
  {
    id: 'w-stewardship',
    title: 'Semantic stewardship · reduction',
    kind: 'idea',
    state: 'mise',
    moved: '1h ago',
    people: { lead: 'efdp' },
    evidence: [
      { kind: 'reduction', label: 'today\u2019s reduction · distilling' },
      { kind: 'thread',    label: '14 messages · 3 threads' },
    ],
    attention: { ceo: 'know', cto: 'watch', em: 'know', keem: 'watch', efdp: 'act' },
    facets: {
      ceo: 'efdp distilling a "stewardship" frame for how we cite chat in AI. Worth ten minutes when he circulates.',
      cto: 'Foundational. Defines the contract every AI surface in Tenun must honor for citations \u2014 Loom, Tapestry, Echo all downstream.',
      em:  'efdp in flow \u2014 don\u2019t interrupt. Expected to circulate end of week.',
      keem:'Implies a `citation_state` projection. Cheap to read; recompute on parent edit. I can host the schema review.',
      efdp:'Today\u2019s reduction. Working line: "whoever cites it, stewards it." Five lenses sketched; Ask still open.',
    },
    handsUp: { from: 'efdp', to: 'keem', ask: 'Schema review when ready?' },
  },
  {
    id: 'w-lv1',
    title: 'LiveView 1.0 upgrade · RFC',
    kind: 'change',
    state: 'mise',
    moved: 'starts Thu',
    people: { lead: 'keem' },
    evidence: [
      { kind: 'rfc', label: 'draft Thursday' },
      { kind: 'horizon', label: 'phoenix_live_view 1.0-rc.7' },
    ],
    attention: { ceo: 'hidden', cto: 'watch', em: 'know', keem: 'act', efdp: 'watch' },
    facets: {
      ceo: 'Tech refresh. Invisible to customers. Drops ~200 LOC of hand-rolled plumbing.',
      cto: 'Aligned. Worth doing in June after the canary settles. Keem leads.',
      em:  'Keem owns the RFC. About four focused days for one engineer.',
      keem:'Streams plus async assigns. We delete `LiveTenun.MessageList.virtualize/2` and lean on the framework.',
      efdp:'Removes three stale abstractions. Strictly compressing. I want to review the streams API before keem freezes.',
    },
  },

  // ─── Order — called in, not started ───
  {
    id: 'w-pricing',
    title: 'Pricing rename · Growth \u2192 Studio',
    kind: 'decision',
    state: 'order',
    moved: 'called 6h ago',
    people: { lead: 'mina', stakeholders: ['dave','ceo'] },
    evidence: [
      { kind: 'decision', label: 'go / no-go · Jun 10 launch' },
    ],
    attention: { ceo: 'act', cto: 'know', em: 'watch', keem: 'know', efdp: 'know' },
    facets: {
      ceo: 'Decide by Wed. Studio polls 23% better in customer interviews. Want this for the Jun 10 launch.',
      cto: 'Low tech risk. Touches billing config and four places in-app. One migration on `subscriptions`.',
      em:  'Mina owns. Three stakeholders to align: dave, keem, legal. Decision by Wed.',
      keem:'Pure rename. Constants live in one module. Subscription tier column gets a new label, no schema break.',
      efdp:'Brand reduction. Tier semantics don\u2019t change. Doc updates fan out from one place.',
    },
    askFor: { ceo: 'Go / no-go on Studio for Jun 10.' },
    handsUp: { from: 'mina', to: 'ceo', ask: 'Need your nod by Wed.' },
  },
  {
    id: 'w-hire',
    title: 'Senior Eng (Search) · backfill',
    kind: 'hire',
    state: 'order',
    moved: 'called 2d ago',
    people: { lead: 'keem', stakeholders: ['ceo','em'] },
    evidence: [
      { kind: 'decision', label: 'level + comp band · need CEO nod' },
    ],
    attention: { ceo: 'act', cto: 'watch', em: 'act', keem: 'know', efdp: 'know' },
    facets: {
      ceo: 'Sign-off needed on level + band. Two candidates queued; debriefs end of week.',
      cto: 'L5/L6 IC for search & retrieval. Avoid manager overhead at this stage.',
      em:  'I\u2019d like a decision by Wed so I can run debriefs Thu/Fri and not stall the pipeline.',
      keem:'Looking for someone who\u2019s debugged pgvector or its peers in production. Few of those around.',
      efdp:'Tilt toward someone with bias to distillation over expansion. Hard to spec on a JD; show up to the panels.',
    },
    askFor: { ceo: 'Level + band sign-off.' },
    handsUp: { from: 'keem', to: 'ceo', ask: 'Sign-off on L6 + comp band before Wed?' },
  },

  // ─── Walked — off the line ───
  {
    id: 'w-pgvec',
    title: 'pgvector backfill',
    kind: 'change',
    state: 'walked',
    moved: 'walked 18h ago',
    people: { lead: 'mina' },
    evidence: [
      { kind: 'metric', label: '14.2M rows · 0 retries' },
    ],
    attention: { ceo: 'know', cto: 'know', em: 'know', keem: 'know', efdp: 'know' },
    facets: {
      ceo: 'Done. Coverage at 100%; semantic search is live in the composer.',
      cto: 'Quiet success. Zero retries on a long-running batch job is what we built for.',
      em:  'Mina freed up. Available for the citation work this week.',
      keem:'Now we can revisit `m` / `ef_construction` on pgvector 0.8 with confidence.',
      efdp:'Substrate ready. Citation stewardship can assume coverage.',
    },
  },
  {
    id: 'w-otel',
    title: 'OTel · channel span attribution',
    kind: 'change',
    state: 'walked',
    moved: 'walked yesterday',
    people: { lead: 'riko' },
    evidence: [
      { kind: 'pr', label: '#1840 · live' },
    ],
    attention: { ceo: 'hidden', cto: 'know', em: 'know', keem: 'watch', efdp: 'know' },
    facets: {
      ceo: 'Quiet plumbing. We can now trace any LiveView channel from join to crash.',
      cto: 'Pays off the next time we debug a stuck subscription.',
      em:  'Riko\u2019s shipping cadence is healthy. One platform task per week is the right rate.',
      keem:'Will need an otel_phoenix 1.5.1 patch next quiet hour \u2014 small fix to channel-span fields.',
      efdp:'A primitive earning interest. Tracing as a precondition for the next layer of debugging tools.',
    },
  },
];

// SLO chips kept as ambient bottom-of-screen context, not a hero panel.
const SLOS_AMBIENT = [
  { svc: 'tenun-web · interactive p99',     budget: 0.83, runway: '17d',  state: 'ok' },
  { svc: 'embeddings.search · p99 < 200ms', budget: 0.34, runway: '4.2d', state: 'burning' },
  { svc: 'loom.summarise · success',        budget: 0.88, runway: '23d',  state: 'ok' },
  { svc: 'tenun-api · 5xx rate',            budget: 0.91, runway: 'on track', state: 'ok' },
];

// Dave's PO read on each work item — attention + facet + linked customer voices.
// Mutates WORK_ITEMS in place so every projection (In Service, Tapestry, drawers)
// sees dave's view alongside the others.
const DAVE_READS = {
  'w-summariser':  { att: 'act',    voice: ['v-ac-1'],
    f: 'Live on canary for both enterprise customers. I want to talk to Acme and Northbay before we raise it; draft CS note ready to send.' },
  'w-northbay':    { att: 'act',    voice: ['v-nb-1','v-nb-2','v-nb-4'],
    f: 'Northbay\u2019s #1 complaint. Hannah named this a renewal risk on the May 26 CSM call. Shipping today \u2014 telling her the moment it lands.' },
  'w-p99':         { att: 'know',
    f: 'Not customer-visible. I only surface to customers if it crosses thresholds.' },
  'w-echo':        { att: 'watch',  voice: ['v-lw-2'],
    f: 'Loomwork asked about Echo\u2019s recency. Pull Marcus in once the flag is flipped; his feedback shaped the time-decay.' },
  'w-stewardship': { att: 'watch',
    f: 'efdp\u2019s reduction. The customer-language version is "we keep your context honest." Useful for Priya\u2019s trust narrative.' },
  'w-lv1':         { att: 'hidden', f: 'Pure plumbing \u2014 hidden from my read.' },
  'w-pricing':     { att: 'act',
    f: 'Survey + 3 customer interview quotes back "Studio". CEO sign-off Wed; CSMs notified Thu; launch Jun 10.' },
  'w-hire':        { att: 'know',
    f: 'Not my call. Flagging only: a search-experienced hire would unlock the DM-search thread Priya raised.' },
  'w-pgvec':       { att: 'know',   voice: ['v-ac-3','v-lw-1'],
    f: 'Foundation laid. We can finally promise "search everywhere" to customers without caveats.' },
  'w-otel':        { att: 'hidden', f: 'Invisible to customers.' },
};

WORK_ITEMS.forEach((it) => {
  const r = DAVE_READS[it.id];
  if (!r) return;
  it.attention = it.attention || {};
  it.attention.dave = r.att;
  it.facets = it.facets || {};
  it.facets.dave = r.f;
  if (r.voice) it.voiceIds = (it.voiceIds || []).concat(r.voice);
});

// Mina's CSM read — relationship lens, not engineering lens.
const MINA_READS = {
  'w-summariser':  { att: 'act',
    f: 'Foundation for Priya\u2019s board-export ask. Citing it in Thu\u2019s QBR; checking with Hannah about when she sees it on her workspace.' },
  'w-northbay':    { att: 'act',
    f: 'I told Hannah this was shipping today. Sending the moment it lands \u2014 want her to feel it before the renewal call Fri.' },
  'w-p99':         { att: 'know',
    f: 'Not customer-visible. Watching only.' },
  'w-echo':        { att: 'watch',
    f: 'Marcus (Loomwork) asked about this. I\u2019ll loop him in once the flag is flipped \u2014 also a beta-invite moment.' },
  'w-stewardship': { att: 'watch',
    f: 'Customer-facing phrase forming: "we keep your context honest." Useful in renewals and case studies.' },
  'w-lv1':         { att: 'hidden', f: 'Plumbing \u2014 hidden from my floor.' },
  'w-pricing':     { att: 'act',
    f: 'I need talking points for all three customers before launch. Different angle per tier; Studio narrative for Northbay/Loomwork, Enterprise stays.' },
  'w-hire':        { att: 'know',
    f: 'Affects how I pitch roadmap. A search-experienced hire would unlock DM-search for Priya.' },
  'w-pgvec':       { att: 'act',
    f: 'I owe Priya and Marcus a "now live" note \u2014 they\u2019ve both asked for "search everywhere." Changelog drafted.' },
  'w-otel':        { att: 'hidden', f: 'Plumbing.' },
};

WORK_ITEMS.forEach((it) => {
  const r = MINA_READS[it.id];
  if (!r) return;
  it.attention = it.attention || {};
  it.attention.mina = r.att;
  it.facets = it.facets || {};
  it.facets.mina = r.f;
});

// Pager state — small footer strip, not a section.
const PAGER_AMBIENT = {
  primary: 'riko', secondary: 'keem',
  until: 'Fri 17:00',
  nextHandoff: 'Fri 17:00 \u2192 mina takes primary',
  week: { pages: 2, mttrAvg: '7m 30s' },
};

const IN_SERVICE_DATA = {
  asOf: 'May 27, 06:14',
  state: 'elevated',                                           // calm | elevated | incident
  stateNote: 'embeddings.search p99 elevated for 6m. Watching.',
  items: WORK_ITEMS,
  slos: SLOS_AMBIENT,
  pager: PAGER_AMBIENT,
};

// ─────────────────────────── The Expo · dave's station ─────────────────────
// Where the PO works. Customer voice arrives, gets clustered into themes,
// shaped into Orders, handed to the kitchen. When work walks, its original
// voice rides back to the customer. Same stream, the front-of-house end.

const VOICE = [
  // ─ Northbay (at-risk, renewal in 9d) ─
  { id: 'v-nb-1', customer: 'northbay', who: 'Hannah Ito',  role: 'Ops Lead',   when: 'May 27 · 06:12', kind: 'support', sentiment: 'negative', text: 'Summary is cutting off mid-sentence in the deploys channel. Third time this week.', themeId: 't-trunc' },
  { id: 'v-nb-2', customer: 'northbay', who: 'Hannah Ito',  role: 'Ops Lead',   when: 'May 25',         kind: 'support', sentiment: 'negative', text: 'When we summarise long threads we lose attribution \u2014 the summary points feel anonymous.', themeId: 't-trunc' },
  { id: 'v-nb-3', customer: 'northbay', who: 'Hannah Ito',  role: 'Ops Lead',   when: 'May 24',         kind: 'nps',     sentiment: 'mixed',    text: 'Can we configure summary length per channel? Deploys wants short; design wants verbose.', themeId: 't-config' },
  { id: 'v-nb-4', customer: 'northbay', who: 'Sam Park',    role: 'Tech Lead',  when: 'May 22',         kind: 'interview', sentiment: 'neutral', text: 'Our team copies summaries into Notion \u2014 needs cleaner formatting to land outside Tenun.', themeId: 't-trunc' },
  { id: 'v-nb-5', customer: 'northbay', who: 'Hannah Ito',  role: 'Ops Lead',   when: 'May 26 · CSM call', kind: 'call', sentiment: 'risk',     text: 'Honestly considering moving back to Slack if this isn\u2019t fixed by renewal.', themeId: 't-risk' },

  // ─ Acme (enterprise, healthy, expansion track) ─
  { id: 'v-ac-1', customer: 'acme', who: 'Priya Ramanan', role: 'VP Eng', when: 'May 24 · CSM call',  kind: 'call',     sentiment: 'positive', text: 'The Loom is the first AI summary I have ever trusted enough to forward to my board.', themeId: 't-export' },
  { id: 'v-ac-2', customer: 'acme', who: 'Priya Ramanan', role: 'VP Eng', when: 'May 24',             kind: 'in-app',   sentiment: 'request',  text: 'Could we get a PDF export of a Loom? I want to share one with my CEO without screenshots.', themeId: 't-export' },
  { id: 'v-ac-3', customer: 'acme', who: 'Priya Ramanan', role: 'VP Eng', when: 'May 21',             kind: 'in-app',   sentiment: 'request',  text: 'Search across DMs would be amazing once we get there.', themeId: 't-dm-search' },

  // ─ Loomwork (growth, healthy) ─
  { id: 'v-lw-1', customer: 'loomwork', who: 'Marcus Vela', role: 'Eng Director', when: 'May 23 · sales call', kind: 'call',  sentiment: 'positive', text: 'Semantic search is the killer feature for us. We did not realise we needed it until we had it.', themeId: 't-export' },
  { id: 'v-lw-2', customer: 'loomwork', who: 'Marcus Vela', role: 'Eng Director', when: 'May 25',              kind: 'in-app',sentiment: 'mixed',    text: 'Echo dedup pulls really old answers sometimes \u2014 stuff from 9 months ago. Can it time-decay?', themeId: 't-echo-recency' },
  { id: 'v-lw-3', customer: 'loomwork', who: 'Marcus Vela', role: 'Eng Director', when: 'May 26',              kind: 'support', sentiment: 'request', text: 'Our PMs want to /decide from the mobile app. Currently a desktop-only ritual.', themeId: 't-mobile' },
];

const THEMES = [
  {
    id: 't-trunc',
    title: 'Summary truncation on long threads',
    voiceIds: ['v-nb-1', 'v-nb-2', 'v-nb-4'],
    customers: ['northbay'],
    sentiment: 'negative',
    state: 'shaped',                            // raw | shaping | shaped | shipped
    orderId: 'o-nb-fix',
    note: 'Northbay\u2019s #1 complaint. 3 voices. Linked to renewal risk theme.',
  },
  {
    id: 't-export',
    title: 'Board-ready / exportable summaries',
    voiceIds: ['v-ac-1', 'v-ac-2', 'v-lw-1'],
    customers: ['acme', 'loomwork'],
    sentiment: 'positive',
    state: 'shaping',
    orderId: 'o-loom-export',
    note: 'Acme\u2019s VP Eng anchored this. Expansion angle.',
  },
  {
    id: 't-config',
    title: 'Configurable summary length per channel',
    voiceIds: ['v-nb-3'],
    customers: ['northbay'],
    sentiment: 'mixed',
    state: 'drafted',
    orderId: 'o-summary-config',
    note: 'Drafted. Small. Worth bundling with the truncation fix.',
  },
  {
    id: 't-echo-recency',
    title: 'Echo dedup time-decay',
    voiceIds: ['v-lw-2'],
    customers: ['loomwork'],
    sentiment: 'mixed',
    state: 'raw',
    note: 'Marcus has a point. Worth flagging to efdp \u2014 already adjacent to citation stewardship.',
  },
  {
    id: 't-mobile',
    title: '/decide from mobile',
    voiceIds: ['v-lw-3'],
    customers: ['loomwork'],
    sentiment: 'request',
    state: 'raw',
  },
  {
    id: 't-dm-search',
    title: 'Semantic search across DMs',
    voiceIds: ['v-ac-3'],
    customers: ['acme'],
    sentiment: 'request',
    state: 'raw',
  },
  {
    id: 't-risk',
    title: 'Northbay renewal risk',
    voiceIds: ['v-nb-5'],
    customers: ['northbay'],
    sentiment: 'risk',
    state: 'meta',
    note: 'Not a shape \u2014 a context flag. Drives priority on summary-truncation.',
  },
];

// Orders Dave has shaped. Some pushed to the work stream (linked to work items);
// some still drafting on his station; one has walked.
const ORDERS = [
  {
    id: 'o-nb-fix',
    title: 'Northbay summary truncation fix',
    state: 'pushed',
    workItemId: 'w-northbay',
    voiceIds: ['v-nb-1', 'v-nb-2', 'v-nb-4'],
    relatedThemes: ['t-trunc', 't-risk'],
    customers: ['northbay'],
    why: 'Northbay\u2019s #1 complaint, surfaced across 3 voices and 2 contacts. Renewal in 9 days. Hannah specifically named it as a churn risk on the May 26 CSM call.',
    what: 'Bound-check on Acc state when chunks end mid-citation. Defensive: ships behind a flag.',
    soThat: 'Northbay no longer sees truncated summaries; we have evidence in hand for the renewal call.',
    size: 'S · ~2d',
  },
  {
    id: 'o-loom-export',
    title: 'Board-ready Loom export',
    state: 'shaping',
    voiceIds: ['v-ac-1', 'v-ac-2'],
    relatedThemes: ['t-export'],
    customers: ['acme', 'loomwork'],
    why: 'Priya called the Loom her first trustworthy AI summary. The natural next ask is sharing it outside Tenun. Acme expansion + Loomwork interest both point here.',
    what: 'PDF / shareable URL export of a Loom summary. Preserves provenance: source ranges, voices, timestamps.',
    soThat: 'When forwarded outside Tenun, the recipient sees authorship and source \u2014 not an unattributable wall of AI text. Defends the trust Priya described.',
    size: 'M · ~5d',
    proposedFor: 'after :loom_v2 raises to 25%',
  },
  {
    id: 'o-summary-config',
    title: 'Channel-level summary length',
    state: 'drafted',
    voiceIds: ['v-nb-3'],
    relatedThemes: ['t-config'],
    customers: ['northbay'],
    why: 'Hannah\u2019s NPS comment. Different channels want different verbosity; one global setting hides this need.',
    what: 'Three modes per channel \u2014 terse / standard / verbose. Persisted on the channel record.',
    soThat: 'Deploys can stay terse; design can stay verbose; no global compromise.',
    size: 'S · ~1d',
  },
  {
    id: 'o-pgvec',
    title: 'pgvector embeddings backfill',
    state: 'walked',
    workItemId: 'w-pgvec',
    voiceIds: ['v-ac-3', 'v-lw-1'],
    customers: ['acme', 'loomwork'],
    why: 'Customers had asked for "search across all of chat" since Q1. Backfilling embeddings was the unblock.',
    what: 'Embed every message and thread reply; recompute on edit.',
    soThat: 'Semantic search works in every workspace, no per-customer ceremony.',
    size: 'L · ~3w',
    tellThem: ['acme', 'loomwork'],
  },
];

const EXPO_DATA = {
  user: 'dave',
  voice: VOICE,
  themes: THEMES,
  orders: ORDERS,
};

// ─────────────────────────── The Floor · mina's station ────────────────────
// The CSM's surface: reading the room, pacing touchpoints, spotting moments,
// carrying shipped work back to customers. Same atoms as everyone else \u2014
// her prism is relationship + revenue, not code.

const FLOOR_DATA = {
  user: 'mina',
  asOf: 'May 27, 06:14',

  // Pulse — quick read of the room.
  pulse: {
    nps7d: 47, npsTrend: '+3',
    arrAtRisk: '$28k',
    arrUpside: '$70k',
    callsThisWeek: 4,
    voicesThisWeek: 11,
  },

  // Moments — things happening right now that want a CSM response.
  moments: [
    {
      kind: 'risk',
      title: 'Northbay renewal in 9 days · the fix lands today',
      customer: 'northbay',
      why: 'Hannah named the truncation issue as a churn risk on the May 26 call. The fix is on the pass.',
      action: 'Tell Hannah the moment it lands; preempt the renewal conversation.',
      heat: 'hot',
      relatedWork: ['w-northbay'],
    },
    {
      kind: 'expansion',
      title: 'Acme is ready for the expansion conversation',
      customer: 'acme',
      why: 'Priya cited the Loom in board prep + seat usage +23% this week. QBR Thursday.',
      action: 'Walk in with the chunked-summariser story + board-export ask captured.',
      heat: 'warm',
      relatedWork: ['w-summariser'],
    },
    {
      kind: 'testimonial',
      title: 'Two quotes worth capturing for case studies',
      customer: null,
      why: '"first AI summary I have ever trusted enough to forward to my board" \u2014 Priya, Acme. "the killer feature" \u2014 Marcus, Loomwork.',
      action: 'Get permission for case studies; both customers are willing.',
      heat: 'cool',
    },
    {
      kind: 'voice',
      title: 'Marcus asked about /decide on mobile',
      customer: 'loomwork',
      why: 'Direct ask via support. Not on the roadmap. Worth a posture in our reply.',
      action: 'Loop in dave; reply by Wed check-in.',
      heat: 'cool',
    },
  ],

  // Call sheet — who needs a touch.
  callSheet: {
    today: [
      { customer: 'northbay', contact: 'Hannah Ito',     kind: 'follow-up',   purpose: 'truncation fix landed', time: '14:00' },
    ],
    thisWeek: [
      { customer: 'loomwork', contact: 'Marcus Vela',    kind: 'check-in',    purpose: '/decide mobile + Echo feedback', time: 'Wed · 11:00' },
      { customer: 'acme',     contact: 'Priya Ramanan',  kind: 'QBR',         purpose: 'expansion conversation',       time: 'Thu · 15:00' },
      { customer: 'northbay', contact: 'Hannah Ito',     kind: 'renewal',     purpose: 'renewal conversation',          time: 'Fri · 10:00' },
    ],
    recent: [
      { customer: 'northbay', contact: 'Hannah Ito',     kind: 'risk call',   when: 'May 26',
        notes: 'Named truncation as a churn risk. Committed to fix by renewal. Agreed to a follow-up the day of the ship.' },
      { customer: 'acme',     contact: 'Priya Ramanan',  kind: 'CSM call',    when: 'May 24',
        notes: 'Board-export ask captured. Cited Loom v2 favourably. Open to a case study.' },
      { customer: 'loomwork', contact: 'Marcus Vela',    kind: 'sales call',  when: 'May 23',
        notes: 'Semantic search praised. Echo recency raised as a small ask. Mobile decide flagged.' },
    ],
  },

  // Renewals & expansion calendar.
  renewals: [
    { customer: 'northbay', when: 'Jun 05',        daysOut: 9,   arrN: 28000,  arrFmt: '$28k',  prob: 'at-risk', state: 'open complaint shipping today',     priority: 1 },
    { customer: 'loomwork', when: 'Nov 22',        daysOut: 179, arrN: 54000,  arrFmt: '$54k',  prob: 'high',    state: 'expansion candidate · +$18k',       priority: 2 },
    { customer: 'acme',     when: 'Feb 14, 2026',  daysOut: 263, arrN: 184000, arrFmt: '$184k', prob: 'high',    state: 'expansion ready · QBR booked',      priority: 3 },
  ],

  // From the kitchen — recently walked / on-the-pass work touching her customers.
  fromKitchen: [
    {
      workItemId: 'w-northbay', state: 'landing',
      tellNotes: 'Hannah specifically named this. Tell her the moment it lands \u2014 preempt the renewal conversation.',
      tellWhom: ['Hannah Ito'],
      readyToSend: true,
    },
    {
      workItemId: 'w-summariser', state: 'canary',
      tellNotes: 'Foundation for the board-export ask Priya raised. Worth opening Thursday\u2019s QBR with this.',
      tellWhom: ['Priya Ramanan'],
    },
    {
      workItemId: 'w-pgvec', state: 'walked',
      tellNotes: 'Foundation for "search across everything" \u2014 Priya and Marcus both asked for this. Changelog drafted.',
      tellWhom: ['Priya Ramanan', 'Marcus Vela'],
      changelogDrafted: true,
    },
  ],
};

window.TENUN = {
  USERS, CHANNELS, DMS,
  MESSAGES: FINAL_MESSAGES,
  THREAD_MESSAGES,
  SUMMARY,
  ON_THE_LOOM,
  CUSTOMERS,
  PR_1842,
  WEEKLY_SPOOL,
  VIEWERS,
  TAPESTRY: TAPESTRY_DATA,
  REDUCTION: REDUCTION_DATA,
  STACK: STACK_DATA,
  IN_SERVICE: IN_SERVICE_DATA,
  EXPO: EXPO_DATA,
  FLOOR: FLOOR_DATA,
};
