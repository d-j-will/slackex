# MCP-Powered Product Discovery Workflow: Feature Discovery

**Research Date:** 2026-03-08
**Method:** Architecture brainstorm, MCP protocol analysis
**Status:** Discovery / Idea capture

---

## 1. Feature Vision

Slackex channels can be linked to GitHub repositories. Users discuss product ideas, feature requests, and refinements conversationally in the channel — especially from mobile. An external AI agent (provided by the user/org, not by Slackex) connects to Slackex via MCP, reads the discussions, and creates/refines GitHub issues on behalf of the team.

**Core insight:** Ideas happen away from the computer. Capturing them conversationally in a mobile chat app is natural. The AI agent does the structured work (issue creation, refinement, labelling) asynchronously.

**Key architectural decision:** Slackex is the platform, not the AI provider. Users/orgs bring their own agent (Claude, GPT, custom). Slackex exposes an MCP server — the agent consumes it.

---

## 2. Why MCP

The Model Context Protocol (MCP) is the right abstraction because:

- **Agent-agnostic** — Any MCP-compatible agent can connect (Claude Desktop, Claude Code, custom agents via Agent SDK, etc.)
- **Standardised interface** — Resources, tools, and prompts are well-defined concepts
- **No AI coupling** — Slackex doesn't run, pay for, or depend on any AI model
- **Composable** — The org's agent can connect to Slackex MCP + GitHub MCP + Linear MCP + whatever else they use, simultaneously
- **Auth boundary is clear** — MCP server controls what the agent can see and do via scoped tokens

---

## 3. Architecture

```
Org's Infrastructure                          Slackex                    GitHub
+------------------------+                  +------------------+       +---------+
| AI Agent               |                  | MCP Server       |       |         |
| (Claude, GPT, custom)  |---MCP (SSE)---→| - channels       |       |         |
|                         |                 | - messages       |       |         |
| Connected MCP servers:  |                 | - threads        |       |         |
|  - Slackex MCP         |                 | - channel-repo   |       |         |
|  - GitHub MCP          |---MCP--------→  |   links          |       |         |
|  - (others)            |                  | - users          |       |         |
+------------------------+                  +------------------+       |         |
                          |                                            |         |
                          +--GitHub API / MCP-------------------------→| Issues  |
                                                                       | PRs     |
                                                                       | Labels  |
                                                                       +---------+

User (mobile)
+----------+
| Slackex  |---message---→ #project-x channel
| mobile   |              (persisted, visible to MCP)
+----------+
```

**Important separation:** Slackex MCP provides access to conversations. GitHub MCP (or API) provides access to issues. The agent orchestrates between them — Slackex doesn't need to know about GitHub at all.

---

## 4. Slackex MCP Server

### 4.1 Resources (Read Access)

Things the agent can read:

| Resource | URI Pattern | Description |
|----------|-------------|-------------|
| Channel list | `slackex://channels` | Channels the token has access to |
| Channel messages | `slackex://channels/{id}/messages` | Recent messages, paginated |
| Thread | `slackex://channels/{id}/threads/{message_id}` | Full thread from a message |
| Channel metadata | `slackex://channels/{id}` | Name, description, linked repos, members |
| User info | `slackex://users/{id}` | Display name, role |

### 4.2 Tools (Write Access)

Things the agent can do:

| Tool | Description |
|------|-------------|
| `send_message` | Post a message to a channel (as the agent's bot user) |
| `reply_to_thread` | Reply to a specific thread |
| `react_to_message` | Add a reaction (e.g., eyes emoji to acknowledge processing) |
| `get_thread_context` | Fetch full thread with participant info and timestamps |
| `search_messages` | Search channel history (leverages existing FTS/semantic search) |

### 4.3 Prompts (Optional)

Pre-built prompt templates the agent can use:

| Prompt | Description |
|--------|-------------|
| `summarise_thread` | Given a thread URI, produce a structured summary |
| `draft_issue` | Given a discussion, draft a GitHub issue with title, body, labels |
| `refine_issue` | Given an existing issue + new discussion, suggest updates |

### 4.4 What Slackex Does NOT Provide

- No GitHub integration — the agent connects to GitHub separately
- No AI model — the agent brings its own
- No issue storage — issues live in GitHub (or Linear, Jira, whatever the org uses)
- No workflow orchestration — the agent decides when and how to act

---

## 5. Authentication & Authorization

### 5.1 MCP Auth

The MCP server needs to authenticate the connecting agent and scope its access:

- **API tokens** — Org-level or user-level tokens with scoped permissions
- **OAuth2** — For richer integrations (agent acts on behalf of a specific user)
- **Channel-scoped access** — A token might only grant access to specific channels

### 5.2 Bot User

When the agent posts messages, it appears as a bot user in the channel:

- Distinct avatar and name (e.g., "Acme Product Bot")
- Clearly identifiable as non-human
- Messages from the bot could have a visual treatment (subtle background, bot badge)
- Org configures the bot identity when setting up MCP access

### 5.3 Permission Model

```
Org Admin
  └── Creates MCP API token
       ├── Scoped to specific channels
       ├── Read: messages, threads, users
       ├── Write: send messages, react
       └── Linked to a bot user identity
```

---

## 6. User Experience

### 6.1 Mobile-First Capture Flow

```
User opens Slackex on phone
  → Opens #project-x channel
  → Types: "We need a way to bulk-import contacts from CSV.
     Should validate email format and dedupe against existing contacts.
     Maybe a drag-and-drop zone on the contacts page?"
  → Goes about their day

Later, the org's agent (running on their infra):
  → Reads the message via MCP
  → Drafts a GitHub issue with title, description, acceptance criteria
  → Posts in the thread: "I've drafted issue #142 from this discussion:
     [link]. Want me to refine anything?"

User (still on mobile):
  → Reads the draft in the thread
  → Replies: "Add a note about max file size, say 10MB.
     And label it 'enhancement' not 'feature'"
  → Agent updates the issue via GitHub API
```

### 6.2 Discussion-to-Issue Flow

For longer discussions involving multiple people:

```
Alice: "Users keep asking for dark mode"
Bob: "Yeah, we should do it. CSS variables would make it straightforward"
Carol: "Don't forget the logo variants — we need light and dark versions"
Alice: "@bot create an issue from this thread"

Bot: "Created issue #156: 'Add dark mode support'
      - CSS variables approach
      - Light/dark logo variants needed
      - Labels: enhancement, ui
      [View on GitHub](link)

      Want me to add acceptance criteria?"

Bob: "Yes, and break it into subtasks"
Bot: "Updated #156 with acceptance criteria and created 3 sub-issues:
      - #157: CSS variable theming infrastructure
      - #158: Dark mode colour palette
      - #159: Logo variants for light/dark themes"
```

### 6.3 Issue Refinement Flow

```
Alice: "@bot refine #142 — we decided to support XLSX too, not just CSV"
Bot: "Updated #142:
      - Title: 'Bulk import contacts from CSV and XLSX'
      - Added XLSX parsing to acceptance criteria
      - Added 'xlsx' label
      [View diff](link)"
```

---

## 7. Channel-Repo Linking

Channels can be linked to one or more GitHub repositories. This is metadata that the MCP server exposes — the agent uses it to know where to create issues.

### 7.1 Data Model

```elixir
# New schema — lightweight join table
%ChannelRepoLink{
  channel_id: snowflake,
  repo_owner: String.t(),     # e.g., "acme-corp"
  repo_name: String.t(),      # e.g., "web-app"
  linked_by: user_id,
  linked_at: DateTime.t()
}
```

### 7.2 Linking UX

- Channel settings → "Linked Repositories" → Add repo (owner/name)
- Displayed in channel header or info panel
- MCP resource `slackex://channels/{id}` includes linked repos in metadata

### 7.3 Slackex Doesn't Need GitHub Access

The channel-repo link is just metadata — a string like `"acme-corp/web-app"`. Slackex stores it and exposes it via MCP. The agent is the one that actually talks to GitHub. Slackex never needs a GitHub token.

---

## 8. Implementation Considerations

### 8.1 MCP Transport

MCP supports multiple transports:

- **SSE (Server-Sent Events)** — HTTP-based, works through firewalls, stateless-ish. Good for remote agents.
- **stdio** — For local agents. Not applicable here since the agent is remote.
- **Streamable HTTP** — Newer transport option, request-response with optional streaming.

SSE or Streamable HTTP are the right choices for a remote MCP server.

### 8.2 Elixir MCP Server Implementation

Options for implementing the MCP server in Elixir:

- **Custom implementation** — MCP is a JSON-RPC protocol over SSE. Phoenix can serve SSE natively. Implement the protocol handler as a Phoenix controller or plug.
- **Existing libraries** — Check if an Elixir MCP server library exists (the ecosystem is young).
- **Sidecar** — Run a TypeScript/Python MCP server that talks to Slackex's internal API. More operational overhead but more library support.

### 8.3 Rate Limiting & Quotas

The MCP server should enforce:

- Request rate limits per token
- Message fetch pagination limits
- Write rate limits (prevent bot spam)

### 8.4 Real-Time vs Polling

Two models for how the agent stays aware of new messages:

- **Polling** — Agent periodically fetches new messages via MCP resources. Simple but latent.
- **Subscriptions** — MCP supports resource subscriptions. Agent subscribes to a channel; Slackex pushes notifications when new messages arrive. More complex but real-time.

Resource subscriptions via SSE would let the agent react to messages as they happen.

---

## 9. What Makes This Interesting

### 9.1 Platform Play

Slackex becomes a **platform** that agents plug into, not a monolithic app:

- Today: Product discovery agent (discussions → GitHub issues)
- Tomorrow: Support triage agent, standup summariser, onboarding bot, CI notification agent
- Each org brings their own agents with their own AI providers
- Slackex's value is the conversational data + real-time transport, not the AI

### 9.2 Composability

Because MCP is composable, the agent can connect to multiple services simultaneously:

```
Agent connects to:
  ├── Slackex MCP     → reads discussions
  ├── GitHub MCP      → creates/updates issues
  ├── Linear MCP      → alternative issue tracker
  ├── Notion MCP      → updates product docs
  └── Slack MCP       → cross-posts to external Slack (if needed)
```

Slackex doesn't need to build integrations with all these services. The agent is the integration layer.

### 9.3 Mobile-First Product Work

The real value proposition: product discovery and issue management feels like texting, not like navigating a project management UI on a small screen.

---

## 10. Scope Considerations

### Minimum Viable Version

1. MCP server with read access to channels and messages
2. MCP server with write access (send message as bot)
3. API token auth with channel-scoped permissions
4. Channel-repo link metadata
5. Bot user identity per org/token

### What Can Wait

- Resource subscriptions (polling is fine initially)
- Prompt templates (agent can bring its own)
- OAuth2 (API tokens are sufficient to start)
- Bidirectional GitHub sync (issue status → channel notifications)
- Message search via MCP (agent can read messages linearly first)

---

## 11. Open Questions

1. **MCP server library for Elixir** — Does one exist, or is this a custom JSON-RPC implementation over SSE?
2. **Auth model** — API tokens per org? Per user? Per channel? What granularity makes sense for v1?
3. **Bot message rendering** — How should bot messages look in the UI? Distinct styling? Collapsible? Threaded by default?
4. **Agent triggering** — Does the agent poll, subscribe to real-time events, or only act when explicitly mentioned (@bot)?
5. **Multi-repo channels** — Can a channel link to multiple repos? How does the agent disambiguate?
6. **Conversation boundaries** — How does the agent know where one "feature discussion" ends and another begins within a channel? Threads help, but not all discussions are threaded.
7. **Audit trail** — Should Slackex log what the agent read/wrote for transparency? ("Bot read 47 messages in #project-x at 14:32")
8. **Rate of MCP ecosystem adoption** — How many potential users already have MCP-compatible agents they'd connect?
9. **Existing Slackex search** — The FTS/semantic search infrastructure could be exposed via MCP, letting agents search across channel history intelligently. High value, low incremental effort.
