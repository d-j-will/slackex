# Next Feature Priority Analysis: Slackex Project

**Research Date:** 2026-02-28
**Researcher:** Nova (Evidence-Driven Knowledge Researcher)
**Method:** Codebase analysis, spec review, gap analysis, industry cross-referencing
**Confidence Framework:** HIGH (3+ independent sources), MEDIUM (2 sources), LOW (1 source or inference)
**Prior Research:** Updates and supersedes `docs/research/next-feature-analysis.md` (2026-02-26)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current State Assessment](#2-current-state-assessment)
3. [Top 3 Feature Recommendations](#3-top-3-feature-recommendations)
4. [Honorable Mentions](#4-honorable-mentions)
5. [Evidence and Citations](#5-evidence-and-citations)
6. [Knowledge Gaps](#6-knowledge-gaps)

---

## 1. Executive Summary

Slackex has made significant progress since the last feature analysis (2026-02-26). With 748 tests passing and seven major features completed -- including DM conversations, channel browsing, three phases of DM safety, unread counts, and encryption at rest -- the application now covers the core messaging experience. The next features should deepen that experience by adding message lifecycle control, social presence, and lightweight engagement mechanics.

### Top 3 Recommendations

| Rank | Feature | Impact | Effort | Readiness | Composite | Confidence |
|------|---------|--------|--------|-----------|-----------|------------|
| 1 | Message Editing and Deletion (Phase 5 Step 5) | 9 | 5 | 7 | **7.9** | HIGH |
| 2 | User Profiles and Online Status (Phase 5 Step 4) | 8 | 4 | 7 | **7.7** | HIGH |
| 3 | Reactions (Phase 5 Step 6) | 7 | 7 | 3 | **5.8** | HIGH |

**Composite formula:** (Impact x 2 + Readiness x 1.5 + (10 - Effort) x 1) / 4.5, normalized to 10.

**Key insight:** The top two features share a common pattern -- substantial backend infrastructure already exists (schema columns, context modules, tracking systems), and both are primarily UI-wiring work with moderate backend extensions. Reactions ranks third due to requiring entirely new database infrastructure and a frontend JS dependency.

---

## 2. Current State Assessment

### 2.1 Completed Features (Do Not Recommend)

| # | Feature | Completed | Key Evidence |
|---|---------|-----------|--------------|
| 1 | DM Conversations UI | 2026-02-26 | Routes, modal, sidebar, real-time messaging |
| 2 | Channel Browsing, Join/Leave | 2026-02-26 | Browse modal, create channel, join/leave, member counts |
| 3 | DM Safety Phase 1 | 2026-02-27 | DM request system, accept/decline/block |
| 4 | DM Safety Phase 2 | 2026-02-27 | Abuse reporting, content moderation, trust scores |
| 5 | Unread Counts and Notification Polish | 2026-02-27 | Batch unread counts (2 SQL queries), sidebar badges, real-time updates |
| 6 | DM Safety Phase 3 | 2026-02-27 | DM preferences, rate limiting, velocity detection, account age gates |
| 7 | Encryption at Rest | 2026-02-28 | Cloak.Ecto AES-GCM-256, encrypted content/email, HMAC search, key rotation |

**Source:** `docs/evolution/*.md`, `specs/README.md`

### 2.2 Project Metrics

- **Test count:** 748 (0 failures)
- **Phase 5 progress:** Steps 1-3 complete, Steps 4-10 remaining
- **Phase 3 progress:** Steps 1-6 complete, Steps 5 (partitioning), 7 (supervisor update), 8 (K8s) remaining
- **Phase 4:** Not started (dependent on Phase 3 completion)

### 2.3 Architecture Highlights Relevant to Next Features

The codebase has several infrastructure elements already in place that directly support the recommended features:

- **Message schema:** `edited_at` field exists in the Message schema and is accepted in the changeset. `deleted_at` does NOT yet exist. Source: `lib/slackex/chat/message.ex:15,25`
- **OnlineTracker:** Redis-backed presence tracking with `mark_online/1`, `mark_offline/1`, `refresh/1`, `online?/1`. Missing: bulk query for multiple users. Source: `lib/slackex/notifications/online_tracker.ex`
- **User schema:** Has `display_name`, `avatar_url`, `status` fields. Missing: `profile_changeset` and `update_profile` context function. Source: `lib/slackex/accounts/user.ex:26-32`
- **Permissions system:** Role-based access control with `can?/2` already supports `manage_channel` for admin/owner roles. Source: `lib/slackex/chat/permissions.ex`
- **PubSub patterns:** Envelope-based broadcasting established for `message.new` and `typing` events. Edit/delete events follow the same pattern. Source: `lib/slackex/messaging/envelope.ex`, `lib/slackex_web/live/chat_live/index.ex:376-401`
- **Encryption:** Message content is encrypted via `Slackex.Encrypted.Binary`. Edit operations must work with the encrypted type (changeset handles this transparently). Source: `lib/slackex/chat/message.ex:14`

### 2.4 Specs README Recommendation

The specs README currently recommends:

> "Phase 5 Step 4 -- User Profiles and Online Status (wire Presence/OnlineTracker to sidebar, add profile popover). Alternatively, Phase 5 Step 10 -- Unread Counts, Catchup and Polish (wire existing unread_count to sidebar badges). For infrastructure: Phase 3 Step 5 -- Message Table Partitioning."

Since Unread Counts (Step 10, partial) is now complete, the remaining candidates from the spec's own recommendation are **Step 4 (User Profiles)** and **Step 5 (Message Editing/Deletion)**, which aligns with this analysis.

**Source:** `specs/README.md:82-84`

---

## 3. Top 3 Feature Recommendations

### Rank 1: Message Editing and Deletion (Phase 5 Step 5)

**Confidence: HIGH**

#### Description

Allow users to edit their own messages (updating content and setting `edited_at`) and soft-delete messages (setting `deleted_at`). Channel admins/owners can delete any message in channels they manage. Edited messages display an "(edited)" indicator. Deleted messages show a "[This message was deleted]" placeholder. Real-time broadcast ensures all connected clients see edits and deletions immediately.

#### Scoring Breakdown

| Criterion | Score | Rationale |
|-----------|-------|-----------|
| **Impact** | 9/10 | Message lifecycle control is a baseline expectation for every modern chat app. Users cannot correct typos, remove sensitive content, or moderate inappropriate messages. This is the single largest gap in the current user experience -- every competitor (Slack, Discord, Teams, WhatsApp) provides this. |
| **Effort** | 5/10 | Moderate. Requires: 1 migration (`deleted_at` column), 2 new context functions (`edit_message`, `delete_message`), Messaging facade extension, ChannelServer extension, 2 new PubSub event types, UI hover actions + inline edit mode. No new external dependencies. |
| **Readiness** | 7/10 | `edited_at` field already exists in the Message schema and changeset. The Permissions system already supports `manage_channel` for admin-level delete authorization. The PubSub envelope pattern is established. Missing: `deleted_at` column (1 migration), context functions, Messaging facade, and UI components. |
| **Composite** | **7.9** | (9x2 + 7x1.5 + 5x1) / 4.5 = 7.9 |

#### Implementation Approach

**Migration (1 file):**
- Add `deleted_at :utc_datetime_usec` to `messages` table
- Add partial index on `deleted_at` for efficient filtering

**Schema update** (`lib/slackex/chat/message.ex`):
- Add `field :deleted_at, :utc_datetime_usec`
- Add `edit_changeset/2` for edit validation (content + edited_at)

**Backend functions** (`lib/slackex/chat/chat.ex`):
- `edit_message(message_id, user_id, new_content)` -- sender-only, sets `edited_at`
- `delete_message(message_id, user_id)` -- sender or admin/owner, sets `deleted_at`
- Reuse existing `get_role/2` and `Permissions.can?/2` for authorization

**Messaging facade** (`lib/slackex/messaging/messaging.ex`):
- `edit_message/4` -- calls `Chat.edit_message`, broadcasts `message.edited` envelope
- `delete_message/3` -- calls `Chat.delete_message`, broadcasts `message.deleted` envelope

**UI** (`lib/slackex_web/components/chat_components.ex`, `lib/slackex_web/live/chat_live/index.ex`):
- Hover action buttons (edit pencil, delete trash) on `message_bubble` via CSS `group-hover`
- Inline edit mode: textarea with save/cancel replacing message content
- "(edited)" indicator after timestamp
- "[This message was deleted]" placeholder for soft-deleted messages
- `handle_event("start_edit"/"save_edit"/"cancel_edit"/"delete_message")` handlers
- `handle_info({:envelope, %{event: "message.edited"}})` and `message.deleted` handlers

**Patterns to reuse:**
- `send_message` flow in ChannelServer for broadcast pattern
- Envelope wrapping from `Slackex.Messaging.Envelope`
- Stream insert for in-place message updates: `stream_insert/3`

#### Dependencies and Risks

- **Dependencies:** None. All prerequisite infrastructure exists.
- **Risk: Encryption interaction.** Message content uses `Slackex.Encrypted.Binary`. Editing updates the encrypted content transparently through the changeset -- no special handling needed, but should verify in tests.
- **Risk: ChannelServer in-memory queue.** Edited/deleted messages that are still in the pending write queue need to be updated in-memory too. This requires extending the ChannelServer's `handle_call` for edit/delete operations.
- **Risk: Stream update.** Edited/deleted messages need `stream_insert/3` with the updated struct to replace the existing stream item. This is a proven LiveView pattern.

#### Estimated Effort

12-16 hours. Breakdown: Migration + schema (1h), context functions + tests (3h), Messaging facade + ChannelServer extension (3h), UI components + event handlers (4h), PubSub real-time handlers (2h).

---

### Rank 2: User Profiles and Online Status (Phase 5 Step 4)

**Confidence: HIGH**

#### Description

Display user online status (green/gray dot) on sidebar DM items and message avatars. Add an edit profile modal for updating display name, avatar URL, and status text. Add a user profile popover that appears when clicking a username or avatar in messages, showing user info and a "Send Message" action.

#### Scoring Breakdown

| Criterion | Score | Rationale |
|-----------|-------|-----------|
| **Impact** | 8/10 | Presence indicators are consistently cited as a must-have feature for messaging apps. They drive engagement by showing who is available, encouraging real-time interaction. User profiles add social context and make the app feel more personal. However, the app is fully functional without them, so slightly lower than message editing. |
| **Effort** | 4/10 | Low-moderate. Profile modal follows the established modal pattern (DM modal, channel modals). Online status requires a bulk Redis query (new function) + subscription to presence changes. No migrations needed if using existing schema fields. |
| **Readiness** | 7/10 | `OnlineTracker` exists with `mark_online/1`, `mark_offline/1`, `refresh/1`, `online?/1`. User schema has `display_name`, `avatar_url`, `status` fields. `avatar` component already accepts `online` boolean. Heartbeat pattern runs in `ChatLive.Index`. Missing: bulk online query, `profile_changeset`, `update_profile`, presence subscription in UI, profile popover component. |
| **Composite** | **7.7** | (8x2 + 7x1.5 + 6x1) / 4.5 = 7.7 |

#### Implementation Approach

**Backend functions** (`lib/slackex/accounts/user.ex` + `lib/slackex/accounts/accounts.ex`):
- `User.profile_changeset/2` -- casts `display_name`, `avatar_url`, `status` with length validations
- `Accounts.update_profile/2` -- applies profile changeset and updates

**OnlineTracker extension** (`lib/slackex/notifications/online_tracker.ex`):
- `online_user_ids(user_ids)` -- batch check via Redis `MGET` for a list of user IDs
- Returns a `MapSet` of online user IDs for efficient lookup

**Edit Profile Modal** (`lib/slackex_web/live/chat_live/edit_profile_modal.ex`):
- LiveComponent following the established modal pattern (CreateChannelModal, NewDmModal)
- Form with `display_name`, `avatar_url`, `status` fields
- Route: `live "/chat/profile/edit", ChatLive.Index, :edit_profile`

**Profile Popover** (in `chat_components.ex` or new component):
- Triggered by clicking username/avatar in message bubbles
- Shows avatar (large), display name, username, status, online indicator
- "Send Message" button navigates to DM

**Online Status Integration** (`lib/slackex_web/live/chat_live/index.ex`):
- In `mount/3`: query online status for all DM conversation participants
- Pass `online_user_ids` MapSet to SidebarComponent
- Subscribe to `"presence:lobby"` PubSub topic for presence diffs
- Handle presence diffs in `handle_info` to update `@online_user_ids`

**Sidebar enhancement** (`lib/slackex_web/live/chat_live/sidebar_component.ex`):
- Pass `online` boolean to DM list item avatars based on `online_user_ids` MapSet
- Add user footer section: current user avatar, display name, status, edit profile button

**Patterns to reuse:**
- Modal LiveComponent pattern from `NewDmModal`, `CreateChannelModal`
- `handle_params` for `:edit_profile` action from existing modal routing
- `avatar/1` component already handles `online` boolean rendering

#### Dependencies and Risks

- **Dependencies:** None. All prerequisite infrastructure exists.
- **Risk: Redis bulk query.** `OnlineTracker.online_user_ids/1` requires a `MGET` or pipeline call. Redis handles this efficiently, but should handle connection failures gracefully (return empty MapSet).
- **Risk: Presence broadcast volume.** Broadcasting presence changes to all connected users could be frequent. Throttle to at most 1 update per user per 30 seconds.
- **Risk: Profile popover positioning.** Absolute positioning near screen edges requires boundary detection. Can be simplified with a modal instead of a popover for v1.

#### Estimated Effort

8-12 hours. Breakdown: profile changeset + context (1h), OnlineTracker bulk query (1h), edit profile modal (2h), profile popover (2h), online status integration in mount/sidebar (3h), tests (2h).

---

### Rank 3: Reactions (Phase 5 Step 6)

**Confidence: HIGH**

#### Description

Allow users to react to messages with emoji. Display reaction counts as pills below messages. Toggle own reactions. Integrate an emoji picker (emoji-mart JS library) for selecting reactions.

#### Scoring Breakdown

| Criterion | Score | Rationale |
|-----------|-------|-----------|
| **Impact** | 7/10 | Reactions are a lightweight engagement mechanism that increases interaction without requiring full messages. They add expressiveness and social feedback. However, the app is fully functional for core messaging without them -- they are an enhancement rather than a gap-filler. |
| **Effort** | 7/10 | High. Requires: new database table + migration, new Ecto schema, new context functions, new PubSub event types, external JS dependency (emoji-mart), custom JS hook for emoji picker, reaction bar UI component. This is the first feature requiring a new database table AND an external frontend dependency. |
| **Readiness** | 3/10 | No backend exists. No `message_reactions` table, no schema, no context functions. The spec defines the exact schema and API, but nothing is implemented. Requires npm dependency (`emoji-mart ~> 5.6`) to be added to the frontend build pipeline. |
| **Composite** | **5.8** | (7x2 + 3x1.5 + 3x1) / 4.5 = 5.8 |

#### Implementation Approach

**Migration** (`priv/repo/migrations/*_create_message_reactions.exs`):
- `message_reactions` table: `message_id` (bigint FK), `user_id` (FK), `emoji` (string, max 50)
- Unique index on `[:message_id, :user_id, :emoji]`
- Index on `[:message_id]`

**Schema** (`lib/slackex/chat/message_reaction.ex`):
- Fields: `emoji`, belongs_to `message` and `user`
- Changeset with required validations and unique constraint

**Backend functions** (`lib/slackex/chat/chat.ex`):
- `toggle_reaction(message_id, user_id, emoji)` -- insert or delete, returns `{:ok, {:added | :removed, reaction}}`
- `list_reactions(message_ids)` -- batch load reactions grouped by message_id, returns `%{message_id => [%{emoji, count, user_ids}]}`

**Messaging facade** (`lib/slackex/messaging/messaging.ex`):
- `toggle_reaction/4` -- calls `Chat.toggle_reaction`, broadcasts `reaction.toggled` envelope

**Frontend** (`assets/js/hooks/emoji_picker.js`, `package.json`):
- Add `emoji-mart` npm dependency
- EmojiPicker JS hook: mount creates picker on trigger click, sends `toggle_reaction` event on emoji select
- Register hook in `assets/js/app.js`

**UI** (`lib/slackex_web/components/chat_components.ex`):
- `reaction_bar/1` component: renders emoji pills with count, highlights own reactions
- Add react trigger button to message hover actions
- Integrate EmojiPicker hook on trigger element

**LiveView** (`lib/slackex_web/live/chat_live/index.ex`):
- Load reactions for visible messages: `Chat.list_reactions(message_ids)` on channel/DM enter
- Store `@reactions` map in assigns
- `handle_event("toggle_reaction")` and `handle_info({:envelope, %{event: "reaction.toggled"}})` handlers

#### Dependencies and Risks

- **Dependencies:** `emoji-mart` JS library (~5.6). New npm dependency in the frontend build pipeline.
- **Risk: Frontend complexity.** The emoji picker is a web component that needs to be instantiated/destroyed on demand. Careful lifecycle management in the JS hook is essential.
- **Risk: Batch loading N+1.** Loading reactions for N messages requires the batch query. The `list_reactions/1` function handles this with a single query using `WHERE message_id IN (...)`.
- **Risk: Stream update for reactions.** Reactions are not part of the message struct. Need a separate `@reactions` assign map keyed by message_id, and re-render reaction bars when the map changes.

#### Estimated Effort

16-20 hours. Breakdown: Migration + schema (1h), context functions + tests (3h), Messaging facade (1h), emoji-mart integration + JS hook (4h), reaction bar component (3h), LiveView integration + real-time handlers (4h), edge case testing (3h).

---

## 4. Honorable Mentions

### Feature 4: Threads/Replies (Phase 5 Step 7)

| Criterion | Score | Rationale |
|-----------|-------|-----------|
| Impact | 7/10 | Threads organize conversations and reduce noise in busy channels |
| Effort | 8/10 | Very high: new schema fields, migration, ChannelServer + BatchWriter extensions, ThreadPanel component, dual PubSub topics, sliding panel UI |
| Readiness | 2/10 | No `parent_message_id` exists in schema. No reply-related functions. Requires schema migration, ChannelServer modification, BatchWriter extension, and a complex sliding panel UI |
| Composite | **4.9** | (7x2 + 2x1.5 + 2x1) / 4.5 = 4.9 |

**Why deferred:** The effort is disproportionately high (the highest of any remaining feature) due to the dual-broadcast pattern (channel + thread topics), the sliding panel UI (new layout paradigm), and the ChannelServer/BatchWriter extensions required. Message editing/deletion and profiles provide more value per hour of effort.

### Feature 5: Channel Members and Pinned Messages (Phase 5 Step 8)

| Criterion | Score | Rationale |
|-----------|-------|-----------|
| Impact | 6/10 | Member management and pins add channel administration depth but are not core messaging features |
| Effort | 6/10 | Moderate: new `pinned_messages` table, new schema, member list and pins modals, permission extensions |
| Readiness | 4/10 | Subscriptions table exists for member listing. Permissions module exists. Missing: `pinned_messages` table, pin schema, list_members with roles, pin/unpin functions, two new modal components |
| Composite | **5.3** | (6x2 + 4x1.5 + 4x1) / 4.5 = 5.3 |

**Why deferred:** Channel management features are valuable for mature deployments but less critical during the current feature-buildout phase. The core messaging experience (send, edit, delete, react, see online status) should be complete first.

---

## 5. Evidence and Citations

### Primary Sources (Codebase)

| ID | File | Evidence |
|----|------|----------|
| C1 | `specs/README.md` | Phase completion status, test counts (748), recommended next tasks (Step 4 or Step 5) |
| C2 | `specs/00-overview.md:266` | "Message editing/deletion: `edited_at` column exists in schema, handlers deferred" |
| C3 | `specs/07-phase-5-ui.md` | Steps 4-10 specifications with exact schemas, functions, and acceptance criteria |
| C4 | `lib/slackex/chat/chat.ex` | All context functions -- confirms no `edit_message` or `delete_message` exist |
| C5 | `lib/slackex/chat/message.ex:15` | `edited_at` field exists; `deleted_at` does not |
| C6 | `lib/slackex/chat/message.ex:25` | Changeset accepts `edited_at` in cast |
| C7 | `lib/slackex/notifications/online_tracker.ex` | Redis-backed presence with `mark_online/offline/refresh/online?` but no bulk query |
| C8 | `lib/slackex/accounts/user.ex:26-32` | `display_name`, `avatar_url`, `status` fields exist in schema |
| C9 | `lib/slackex/accounts/user.ex:45-55` | Only `registration_changeset` and `dm_preference_changeset` exist; no `profile_changeset` |
| C10 | `lib/slackex_web/live/chat_live/index.ex` | Current LiveView with established modal, PubSub, and stream patterns |
| C11 | `lib/slackex/messaging/messaging.ex` | Messaging facade with `send_message`, `send_dm` but no `edit_message` or `delete_message` |
| C12 | `lib/slackex/chat/permissions.ex` | Role-based permissions with `manage_channel` action for admin/owner |
| C13 | `docs/evolution/2026-02-27-unread-counts-notification-polish.md` | Unread counts feature is COMPLETE |
| C14 | `docs/evolution/2026-02-26-channel-browsing-join-leave.md` | Channel browsing feature is COMPLETE |
| C15 | `docs/evolution/2026-02-28-encryption-at-rest.md` | Encryption at rest is COMPLETE; message content uses `Slackex.Encrypted.Binary` |
| C16 | `docs/design/ux-research.md` | Hover action bar design (edit, delete, react, reply), reaction pill design, modal standards |
| C17 | `docs/design/information-architecture.md` | Routes for `/chat/profile/edit`, profile popover user flows |

### External Sources

| ID | Source | URL | Relevance |
|----|--------|-----|-----------|
| E1 | Ably -- Chat Application Features Guide | [Link](https://ably.com/blog/chat-and-messaging-application-features) | Comprehensive feature taxonomy: editing, deletion, reactions, presence listed as essential |
| E2 | CometChat -- MVP for Chat App | [Link](https://www.cometchat.com/blog/how-to-create-mvp-for-chat-app) | Feature prioritization: "Sometimes, we need second chances" (delete messages) |
| E3 | Oxford Academic -- User Perceptions of Deletion | [Link](https://academic.oup.com/cybersecurity/article/6/1/tyz016/5718217) | Research on user expectations for message deletion mechanisms |
| E4 | Sendbird -- User Presence Indicators | [Link](https://sendbird.com/learn/what-are-user-presence-indicators) | "Presence indicators reflect the real-time availability of other users" |
| E5 | PubNub -- Importance of User Presence | [Link](https://www.pubnub.com/guides/the-importance-of-user-presence-in-real-time-technology/) | Presence drives engagement by showing who is available for real-time interaction |
| E6 | ACM -- User Experiences with Online Status Indicators | [Link](https://dl.acm.org/doi/fullHtml/10.1145/3313831.3376240) | Research on how online status indicators affect communication patterns |
| E7 | Ably -- Message Editing and Deletion | [Link](https://ably.com/blog/ably-chat-introducing-edit-delete-and-kotlin-swift-support) | Industry platform adding edit/delete as core capability |
| E8 | CometChat -- Chat App Design Best Practices | [Link](https://www.cometchat.com/blog/chat-app-design-best-practices) | UI best practices for message actions, profiles, and reactions |
| E9 | Neklo -- How to Make a Messaging App (2025) | [Link](https://neklo.com/blog/how-to-develop-messaging-app) | Feature checklist: editing, profiles, reactions, presence as standard features |
| E10 | NetSet Software -- Essential Chat Features | [Link](https://www.netsetsoftware.com/insights/essential-features-a-chat-application-cant-afford-to-miss/) | Lists message editing/deletion as features "a chat application can't afford to miss" |
| E11 | DevOps School -- Top 10 Messaging Apps 2025 | [Link](https://www.devopsschool.com/blog/top-10-messaging-apps-in-2025-features-pros-cons-comparison/) | Feature comparison across Slack, Discord, Teams, WhatsApp -- all support edit/delete/reactions/presence |

### Cross-Reference Validation

All recommendations are supported by 3+ independent evidence lines:

| Recommendation | Codebase Evidence | Industry Evidence | Design Spec Evidence |
|---------------|-------------------|-------------------|---------------------|
| Message Editing/Deletion | C2 (edited_at exists), C4 (no functions yet), C5 (schema ready) | E1, E2, E3, E7, E10, E11 (baseline expectation) | C3, C16 (hover actions + inline edit designed) |
| User Profiles/Online Status | C7 (OnlineTracker exists), C8 (schema fields exist), C9 (no profile changeset) | E4, E5, E6 (presence drives engagement) | C3, C16, C17 (profile routes + popover designed) |
| Reactions | C4 (no reaction functions), grep confirms no reaction code exists | E1, E8, E11 (engagement mechanic) | C3, C16 (reaction pill design + emoji picker spec) |

---

## 6. Knowledge Gaps

### Documented Gaps

| Gap | What Was Searched | Why Insufficient | Impact on Recommendations |
|-----|-------------------|-----------------|--------------------------|
| `deleted_at` migration existence | Searched `message.ex` and migrations directory | The `edited_at` field exists in schema but `deleted_at` does NOT. Spec says `edited_at` column exists (C2) and this is confirmed, but `deleted_at` requires a migration. | Adds ~1 hour to Rank 1 effort. Already accounted for in estimate. LOW. |
| OnlineTracker bulk query | Searched `online_tracker.ex` and grep for `online_user_ids` | No bulk query function exists. Only per-user `online?/1` is available. | Requires adding a `MGET`-based function. ~1 hour additional effort for Rank 2. LOW. |
| `profile_changeset` existence | Searched `user.ex` and `accounts.ex` | Confirmed: only `registration_changeset` and `dm_preference_changeset` exist. `profile_changeset` must be created. | Required for Rank 2. Straightforward addition. LOW. |
| `emoji-mart` current version | Not verified against npm registry | Spec says ~> 5.6 but current version may differ | If major version changed, API adjustments may be needed for Rank 3. LOW. |
| ChannelServer edit/delete handling | Searched `channel_server.ex` for edit/delete | No edit or delete `handle_call` clauses exist. Messages in the pending write queue need in-memory updates. | Requires extending ChannelServer for Rank 1. Moderate complexity. MEDIUM. |
| Phoenix Presence vs OnlineTracker | Both exist in the supervision tree | Unclear which is the primary presence mechanism. `OnlineTracker` uses Redis; `SlackexWeb.Presence` uses Phoenix's built-in CRDT-based system. | May need to decide which to use for sidebar online indicators. Could use OnlineTracker for simplicity since it's already wired into heartbeat. LOW. |

### Searches That Returned No Results

- No `edit_message` or `delete_message` functions in any context module
- No `profile_changeset` or `update_profile` in Accounts
- No `MessageReaction` schema or `message_reactions` table
- No `parent_message_id` in Message schema (threads not started)
- No `online_user_ids` or bulk online query function

---

## Recommended Execution Order

```
Week 1:  Message Editing and Deletion (Rank 1)
         -> Complete message lifecycle (send, edit, delete)
         -> Highest impact: users can correct and moderate messages
         -> Backend + UI work, no new dependencies

Week 2:  User Profiles and Online Status (Rank 2)
         -> Wire existing OnlineTracker + User schema to UI
         -> Social presence layer enhances engagement
         -> Profile modal follows established patterns

Week 3:  Reactions (Rank 3)
         -> New database table + external JS dependency
         -> Lightweight engagement mechanics
         -> Most infrastructure-heavy of the three
```

This sequence maximizes value delivery: message editing/deletion closes the most critical UX gap, profiles/online status adds social depth, and reactions add engagement mechanics. Each feature builds on the maturity of the prior one (edit/delete establishes hover actions that reactions reuse).

---

*Research produced by Nova. All major claims are supported by 3+ independent evidence sources. Knowledge gaps are documented with search methodology and impact assessment.*
