# Next Feature Priority Analysis v2: Slackex Project

**Research Date:** 2026-02-28
**Researcher:** Nova (Evidence-Driven Knowledge Researcher)
**Supersedes:** `docs/research/next-feature-priority-2026-02-28.md` (v1)
**Method:** Codebase analysis, spec review, gap analysis, industry cross-referencing
**Confidence Framework:** HIGH (3+ independent sources), MEDIUM (2 sources), LOW (1 source or inference)

---

## Table of Contents

1. [Current State Summary](#1-current-state-summary)
2. [Candidate Features Considered](#2-candidate-features-considered)
3. [Top 3 Recommended Features](#3-top-3-recommended-features)
4. [Recommended Implementation Order](#4-recommended-implementation-order)
5. [Evidence and Citations](#5-evidence-and-citations)
6. [Knowledge Gaps](#6-knowledge-gaps)

---

## 1. Current State Summary

### 1.1 Completed Features

Since the v1 analysis earlier today, **User Profiles and Online Status** has been fully implemented and verified. The updated completed feature list:

| # | Feature | Completed | Key Evidence |
|---|---------|-----------|--------------|
| 1 | DM Conversations UI | 2026-02-26 | Routes, modal, sidebar, real-time messaging |
| 2 | Channel Browsing, Join/Leave | 2026-02-26 | Browse modal, create channel, join/leave, member counts |
| 3 | DM Safety Phase 1 | 2026-02-27 | DM request system, accept/decline/block |
| 4 | DM Safety Phase 2 | 2026-02-27 | Abuse reporting, content moderation, trust scores |
| 5 | Unread Counts & Notification Polish | 2026-02-27 | Batch unread counts (2 SQL queries), sidebar badges, real-time updates |
| 6 | DM Safety Phase 3 | 2026-02-27 | DM preferences, rate limiting, velocity detection, account age gates |
| 7 | Encryption at Rest | 2026-02-28 | Cloak.Ecto AES-GCM-256, encrypted content/email, HMAC search, key rotation |
| 8 | **User Profiles & Online Status** | **2026-02-28** | Bulk Redis MGET, profile card, edit profile modal, real-time presence PubSub, 35 new tests |

**Source:** `docs/evolution/*.md`, evolution doc count: 8

### 1.2 Project Metrics

- **Test count:** 783 (0 failures) -- up from 748 in v1
- **Phase 5 progress:** Steps 1-4 complete (plus unread counts from Step 10 partially done), Steps 5-9 remaining
- **Phase 3 progress:** Steps 1-6 complete, Steps 5 (partitioning), 7 (supervisor update), 8 (K8s) remaining
- **Phase 4:** Not started (dependent on Phase 3 completion)

### 1.3 What Changed Since v1

The v1 analysis recommended:
1. Message Editing & Deletion (Rank 1, composite 7.9)
2. User Profiles & Online Status (Rank 2, composite 7.7) -- **NOW COMPLETE**
3. Reactions (Rank 3, composite 5.8)

With User Profiles complete, the ranking needs to be recalculated from the remaining candidates. Additionally, the completed profiles feature establishes new infrastructure patterns (global PubSub topics, MapSet assigns, function components for display-only UI) that reduce effort estimates for subsequent features.

### 1.4 Pre-existing Infrastructure Relevant to Remaining Features

| Infrastructure | Status | Relevance |
|---------------|--------|-----------|
| `edited_at` field in Message schema | Exists, accepted in changeset | Directly supports message editing (Step 5) |
| `deleted_at` field in Message schema | **Does NOT exist** | Requires migration for message deletion (Step 5) |
| Permissions system (`can?/2`, `manage_channel`) | Exists | Supports admin delete, pin, member management |
| PubSub envelope pattern | Established for `message.new`, `typing`, `presence:online`, `profile:updates` | Edit/delete/reaction events follow same pattern |
| Encrypted message content (`Slackex.Encrypted.Binary`) | Exists | Edit operations work transparently through changeset |
| User blocking (`Chat.block_user/2`, `UserBlock` schema) | **Already complete** from DM Safety | Step 9 blocking portion is largely done |
| Unread counts (`batch_unread_counts/1`, sidebar badges) | **Already complete** | Step 10 unread portion is largely done |
| Hover action bar pattern | Designed in `docs/design/ux-research.md` | Shared by edit, delete, react, and reply features |
| Message grouping design | Designed but not implemented | Would benefit from implementation alongside edit/delete |

---

## 2. Candidate Features Considered

Seven candidate features were evaluated from the remaining Phase 5 steps:

| # | Feature | Phase 5 Step | New DB Tables | New JS Dependencies | Estimated Effort |
|---|---------|-------------|---------------|---------------------|-----------------|
| A | Message Editing & Deletion | Step 5 | 0 (1 migration for `deleted_at`) | 0 | 12-16 hours |
| B | Reactions | Step 6 | 1 (`message_reactions`) | 1 (`emoji-mart`) | 16-20 hours |
| C | Threads/Replies | Step 7 | 0 (2 columns added to `messages`) | 0 | 24-30 hours |
| D | Channel Members & Pinned Messages | Step 8 | 1 (`pinned_messages`) | 0 | 14-18 hours |
| E | Invite Links | Step 9 (partial) | 1 (`invite_links`) | 1 (`copy-to-clipboard` hook) | 12-16 hours |
| F | User Blocks UI | Step 9 (partial) | 0 (backend exists) | 0 | 4-6 hours |
| G | Message Table Partitioning | Phase 3 Step 5 | 0 (schema change) | 0 | 8-12 hours |

**Note:** Step 9 (Invite Links & User Blocks) was split because user blocking backend already exists from DM Safety. Only the invite links infrastructure and block UI wiring remain. Step 10 (Unread Counts) is largely complete -- only polish items remain.

---

## 3. Top 3 Recommended Features

### Scoring Methodology

Each feature is scored on four dimensions (1-10 scale):

- **User Impact** (weight 35%): How much does this improve the user experience?
- **Technical Readiness** (weight 20%): How well does existing infrastructure support this?
- **Implementation Speed** (weight 20%): How quickly can this be delivered? (10 = fastest)
- **Strategic Value** (weight 25%): How important is this for the product vision?

**Composite Score** = (Impact x 0.35) + (Readiness x 0.20) + (Speed x 0.20) + (Strategic x 0.25)

---

### Rank 1: Message Editing & Deletion (Phase 5 Step 5)

**Composite Score: 8.15 | Confidence: HIGH**

#### Description

Allow users to edit their own messages (updating content and setting `edited_at`) and soft-delete messages (setting `deleted_at`). Channel admins/owners can delete any message in channels they manage. Edited messages display an "(edited)" indicator. Deleted messages show a "[This message was deleted]" placeholder. Real-time broadcast ensures all connected clients see edits and deletions immediately.

#### Scoring Breakdown

| Criterion | Score | Weight | Weighted | Rationale |
|-----------|-------|--------|----------|-----------|
| **User Impact** | 9/10 | 35% | 3.15 | Message lifecycle control is a baseline expectation for every modern chat app. Users cannot correct typos, remove sensitive content, or moderate inappropriate messages. This is the single largest functional gap in the current experience. Every competitor (Slack, Discord, Teams, WhatsApp, Google Chat) provides this. [E1, E4, E5, E7] |
| **Technical Readiness** | 8/10 | 20% | 1.60 | `edited_at` field already exists in schema and changeset. Permissions system supports `manage_channel` for admin-level delete. PubSub envelope pattern is established (4 event types already in use). Missing: `deleted_at` column (1 migration), context functions, and UI. Raised from 7 to 8 since v1 because the profiles work established additional PubSub patterns and function component conventions that directly apply. |
| **Implementation Speed** | 7/10 | 20% | 1.40 | 12-16 hours. 1 migration, 2 context functions, messaging facade extension, ChannelServer extension, UI hover actions + inline edit mode. No new external dependencies. The hover action bar design is already specified in `docs/design/ux-research.md`. |
| **Strategic Value** | 8/10 | 25% | 2.00 | Completes the message lifecycle (send, edit, delete). Establishes the hover action bar pattern that reactions (Step 6) and threads (Step 7) reuse. Without this, the app feels like a prototype rather than a product. [E2, E6, E8] |
| **Composite** | | | **8.15** | |

#### Implementation Notes

**Migration (1 file):**
- Add `deleted_at :utc_datetime_usec` to `messages` table
- Add partial index on `deleted_at` for efficient soft-delete filtering

**Schema update** (`lib/slackex/chat/message.ex`):
- Add `field :deleted_at, :utc_datetime_usec`
- Add `edit_changeset/2` for edit validation (content + edited_at)

**Backend** (`lib/slackex/chat/chat.ex`):
- `edit_message(message_id, user_id, new_content)` -- sender-only, sets `edited_at`
- `delete_message(message_id, user_id)` -- sender or admin/owner via `Permissions.can?/2`, sets `deleted_at`

**Messaging facade** (`lib/slackex/messaging/messaging.ex`):
- `edit_message/4` and `delete_message/3` with PubSub envelope broadcasts

**UI** (`lib/slackex_web/components/chat_components.ex`, `lib/slackex_web/live/chat_live/index.ex`):
- Hover action buttons (edit pencil, delete trash) on message bubble via CSS `group-hover`
- Inline edit mode: textarea with save/cancel replacing message content
- "(edited)" indicator after timestamp
- "[This message was deleted]" placeholder for soft-deleted messages
- `handle_event` and `handle_info` for edit/delete events

**Key risk:** ChannelServer in-memory queue -- edited/deleted messages still in the pending write queue need in-memory updates. Requires extending `handle_call` clauses.

---

### Rank 2: Reactions (Phase 5 Step 6)

**Composite Score: 6.85 | Confidence: HIGH**

#### Description

Allow users to react to messages with emoji. Display reaction counts as pills below messages. Toggle own reactions on/off. Integrate an emoji picker (emoji-mart JS library) for selecting reactions. Reactions persist across page reloads and update in real-time for all connected clients.

#### Scoring Breakdown

| Criterion | Score | Weight | Weighted | Rationale |
|-----------|-------|--------|----------|-----------|
| **User Impact** | 8/10 | 35% | 2.80 | Reactions are a lightweight engagement mechanism that increases interaction without requiring full messages. Research shows first-time users who add a reaction are 2.3x more likely to return the next day. Reactions are a "high-engagement (>50%), high-retention (>75%)" feature, second only to sending messages. [E3, E9, E10] Raised from 7 to 8 since v1 based on stronger engagement evidence. |
| **Technical Readiness** | 4/10 | 20% | 0.80 | No backend exists. Requires new database table, new Ecto schema, new context functions, new npm dependency (emoji-mart), JS hook, and reaction bar component. However, the PubSub envelope pattern and hover action bar pattern (established in Steps 1-5) reduce integration effort. |
| **Implementation Speed** | 5/10 | 20% | 1.00 | 16-20 hours. This is the first feature requiring both a new database table AND an external frontend dependency. The emoji picker JS hook requires careful lifecycle management. Batch loading (`list_reactions/1`) prevents N+1 but adds query complexity. |
| **Strategic Value** | 9/10 | 25% | 2.25 | Reactions are an activation mechanism for new users and a re-engagement hook for push notifications. They transform the app from a "send messages" tool into an interactive social platform. Every major competitor supports reactions. The engagement data makes this strategically critical for user retention. [E3, E9, E10] Raised from 7 to 9 based on activation/retention evidence. |
| **Composite** | | | **6.85** | |

#### Implementation Notes

**Migration:** New `message_reactions` table with `message_id`, `user_id`, `emoji` fields. Unique index on `[:message_id, :user_id, :emoji]`.

**Schema:** New `Slackex.Chat.MessageReaction` with `toggle_reaction/3` (insert or delete) and `list_reactions/1` (batch load with `array_agg`).

**Frontend:** Add `emoji-mart` npm dependency. Create `EmojiPicker` JS hook in `assets/js/hooks/emoji_picker.js`. Register in `app.js`.

**UI:** `reaction_bar/1` component renders emoji pills with count. Own reactions highlighted with `bg-primary/20`. "+" trigger button opens emoji picker.

**LiveView:** Load `@reactions` map on channel entry. Handle `toggle_reaction` event and `reaction.toggled` PubSub envelope.

**Key risk:** emoji-mart is a web component that needs careful mount/destroy lifecycle in the JS hook. The spec references ~5.6 but the current version should be verified against npm.

**Dependency on Rank 1:** Reactions reuse the hover action bar established by message editing/deletion. Implementing Rank 1 first means the hover action UI pattern is already proven and the react button just slots in.

---

### Rank 3: Channel Members & Pinned Messages (Phase 5 Step 8)

**Composite Score: 6.60 | Confidence: HIGH**

#### Description

Add a channel members modal showing all members with role badges (owner/admin/member/viewer). Admin+ users can promote, demote, and kick members. Add a pinned messages system: admin+ can pin/unpin messages, a pinned messages modal displays pinned content, and the channel header shows member count and pin count with navigation to their respective modals.

#### Scoring Breakdown

| Criterion | Score | Weight | Weighted | Rationale |
|-----------|-------|--------|----------|-----------|
| **User Impact** | 7/10 | 35% | 2.45 | Channel management features add administrative depth. Member visibility and role management are expected in team messaging tools. Pinned messages provide a way to surface important content without scrolling. However, the app is functional for core messaging without these -- they enhance rather than fill a gap. [E1, E11, E12] |
| **Technical Readiness** | 6/10 | 20% | 1.20 | Subscriptions table already exists for member listing. Permissions module has `manage_channel` action. `get_role/2` is implemented. Missing: `pinned_messages` table, `PinnedMessage` schema, `list_members`, `pin_message/unpin_message` functions, two new modal LiveComponents, channel header enhancement. |
| **Implementation Speed** | 6/10 | 20% | 1.20 | 14-18 hours. One migration, one new schema, moderate backend (5-6 new functions), two new modal components (following established modal pattern from browse channels, new DM, edit profile). No external dependencies. |
| **Strategic Value** | 7/10 | 25% | 1.75 | Moves the app from "messaging tool" to "team workspace." Channel administration is a differentiator for workplace use cases. Pinned messages are a lightweight knowledge management feature. These features signal maturity and readiness for team adoption. [E11, E12, E13] |
| **Composite** | | | **6.60** | |

#### Why Channel Members/Pins Over Threads

Threads (Step 7) scored lower in this analysis despite high user impact (7/10) because:

1. **Effort is disproportionate:** 24-30 hours vs 14-18 hours for members/pins. Threads require a new sliding panel UI paradigm, dual PubSub broadcast (channel + thread topics), ChannelServer extension for parent_message_id, BatchWriter extension, and ThreadPanelComponent -- the most complex single feature remaining.
2. **Technical readiness is lowest:** No `parent_message_id` exists. Requires schema migration, new associations, new LiveComponent, new routing, and new panel layout. Readiness score: 2/10.
3. **Channel Members/Pins reuses established patterns:** The modal pattern is proven (3 modals already exist). The permissions system already supports the needed actions. Pins follow the same insert/delete/list pattern as other features.

Threads remain strategically important and should follow as the next feature after these three.

#### Implementation Notes

**Migration:** New `pinned_messages` table with `message_id`, `channel_id`, `pinned_by_id`. Unique index on `[:message_id, :channel_id]`.

**Backend** (`lib/slackex/chat/chat.ex`):
- `list_members(channel_id)` -- join subscriptions with users, return role info
- `update_member_role(channel_id, actor_id, target_id, new_role)` -- permission-checked
- `kick_member(channel_id, actor_id, target_id)` -- permission-checked, owner protection
- `pin_message(channel_id, user_id, message_id)` -- admin+ only
- `unpin_message(channel_id, user_id, message_id)` -- admin+ only
- `list_pinned_messages(channel_id)` -- preload message and sender

**UI:** Two new LiveComponent modals following the established pattern. Channel header enhanced with member count and pin count icons.

**Key risk:** Role hierarchy enforcement -- must prevent owner demotion/kick at the backend level, not just hide UI buttons.

---

## 4. Recommended Implementation Order

```
Phase A (Week 1):  Message Editing & Deletion [Step 5]
  Estimated: 12-16 hours
  Establishes: hover action bar, inline edit pattern, soft-delete pattern
  Unlocks: hover action buttons reused by reactions and threads

Phase B (Week 2):  Reactions [Step 6]
  Estimated: 16-20 hours
  Establishes: emoji picker JS hook, reaction bar component, new DB table pattern
  Unlocks: engagement mechanics, activation/retention improvement

Phase C (Week 2-3): Channel Members & Pinned Messages [Step 8]
  Estimated: 14-18 hours
  Establishes: member management UI, pin/unpin pattern
  Unlocks: channel administration, team workspace features

---
After these three:
  Phase D: Threads/Replies [Step 7] -- highest effort, biggest remaining UX impact
  Phase E: Invite Links [Step 9 partial] -- user growth mechanic
```

### Rationale for This Sequence

1. **Edit/Delete first** because it closes the most critical UX gap and establishes the hover action bar that all subsequent message-level features reuse.
2. **Reactions second** because the engagement/retention data is compelling (2.3x next-day return rate for first-reaction users) and it builds on the hover action bar from Step 5.
3. **Channel Members/Pins third** because it adds team administration depth at moderate effort, following established modal patterns. This provides "workspace maturity" features before tackling the high-complexity threads feature.
4. **Threads deferred to Phase D** because the effort (24-30 hours) is nearly double any other feature and requires a new layout paradigm (sliding panel). With edit/delete, reactions, and member management in place, the app has a complete messaging experience. Threads add conversation organization, which becomes more valuable as the user base grows.

---

## 5. Evidence and Citations

### Primary Sources (Codebase)

| ID | File | Evidence |
|----|------|----------|
| C1 | `specs/README.md` | Phase 5 Steps 1-3 marked Done; Steps 4-10 marked Not started (NOTE: stale -- Step 4 is complete, test count should be 783) |
| C2 | `specs/07-phase-5-ui.md:638-808` | Step 5 spec: migration, schema, backend, UI, acceptance criteria for message editing/deletion |
| C3 | `specs/07-phase-5-ui.md:811-1008` | Step 6 spec: reactions table, schema, emoji picker hook, reaction bar, acceptance criteria |
| C4 | `specs/07-phase-5-ui.md:1011-1188` | Step 7 spec: threads migration, schema, ThreadPanelComponent, dual PubSub, acceptance criteria |
| C5 | `specs/07-phase-5-ui.md:1191-1424` | Step 8 spec: pinned messages, member management, channel header enhancement |
| C6 | `specs/07-phase-5-ui.md:1427-1792` | Step 9 spec: invite links, user blocks (blocking backend already exists) |
| C7 | `lib/slackex/chat/message.ex:15,25` | `edited_at` field exists in schema and is accepted in changeset; `deleted_at` does NOT exist |
| C8 | `lib/slackex/chat/chat.ex` | No `edit_message`, `delete_message`, `toggle_reaction`, `list_reactions`, `pin_message`, or thread functions exist |
| C9 | `lib/slackex/chat/chat.ex:937-989` | `block_user/2`, `unblock_user/2`, `blocked?/2` already implemented from DM Safety |
| C10 | `lib/slackex/chat/chat.ex:886-928` | `batch_unread_counts/1` already implemented |
| C11 | `lib/slackex/chat/permissions.ex` | `can?/2` with `manage_channel` action for admin/owner roles |
| C12 | `lib/slackex/messaging/envelope.ex` | Envelope-based broadcasting established |
| C13 | `docs/evolution/2026-02-28-user-profiles-online-status.md` | User Profiles COMPLETE: 35 new tests, 783 total, MapSet presence, global PubSub, function components |
| C14 | `docs/design/ux-research.md:246-271` | Hover action bar design spec with edit, delete, react, reply buttons |
| C15 | `lib/slackex_web/live/chat_live/index.ex` | Current LiveView with established modal, PubSub, stream, and function component patterns |

### External Sources

| ID | Source | URL | Relevance |
|----|--------|-----|-----------|
| E1 | Ably -- Chat Application Features Guide | [Link](https://ably.com/blog/chat-and-messaging-application-features) | Comprehensive feature taxonomy: editing, deletion, reactions, threads, pins listed as core features |
| E2 | RST Software -- Chat App Must-Have Features 2024 | [Link](https://www.rst.software/blog/chat-app-development-in-2024-must-have-features-and-those-that-add-a-competitive-edge) | Message editing and deletion described as baseline user expectations |
| E3 | GetStream -- Chat UX Best Practices | [Link](https://getstream.io/blog/chat-ux/) | First-reaction users 2.3x more likely to return; reactions are "high-engagement (>50%), high-retention (>75%)" feature |
| E4 | Ably -- Message Editing and Deletion | [Link](https://ably.com/blog/ably-chat-introducing-edit-delete-and-kotlin-swift-support) | Industry chat platform adding edit/delete as core capability: "customers have come to expect a consistent experience" |
| E5 | Delta Chat -- Edit and Delete Release | [Link](https://delta.chat/en/2025-03-26-edit-and-delete-how) | Even decentralized/email-based chat apps now support editing and deletion |
| E6 | Primocys -- Top 10 Chat App Features | [Link](https://primocys.com/top-10-features-your-chat-app-users-will-love/) | Message editing and deletion listed among top features users expect |
| E7 | CometChat -- Chat App Design Best Practices | [Link](https://www.cometchat.com/blog/chat-app-design-best-practices) | UI best practices for message actions, profiles, and reactions |
| E8 | Neklo -- How to Make a Messaging App (2025) | [Link](https://neklo.com/blog/how-to-develop-messaging-app) | Feature checklist: editing, profiles, reactions, presence as standard features |
| E9 | Sceyt -- Essential Chat Features | [Link](https://sceyt.com/blog/must-have-chat-features-for-communication-apps) | Reactions and threads as core engagement features for communication apps |
| E10 | Designli -- Emojis Boost Engagement and Retention | [Link](https://designli.co/blog/emojis-can-boost-engagement-conversion-retention-app/) | Emoji reactions drive engagement, conversion, and retention in apps |
| E11 | LeapXpert -- Slack vs Discord vs Teams | [Link](https://www.leapxpert.com/slack-vs-discord-vs-microsoft/) | Feature comparison: all three support editing, reactions, threads, member management, pins |
| E12 | CometChat -- Chat Features for User Engagement | [Link](https://www.cometchat.com/blog/chat-features-to-boost-user-engagement) | Threading and reactions as complementary engagement features |
| E13 | PubNub -- Common Chat App Features | [Link](https://www.pubnub.com/blog/common-features-of-chat-apps/) | Channel management and moderation tools as standard features |

### Cross-Reference Validation

All three recommendations are supported by 3+ independent evidence lines:

| Recommendation | Codebase Evidence | Industry Evidence | Design Spec Evidence |
|---------------|-------------------|-------------------|---------------------|
| Message Editing/Deletion | C7 (edited_at exists), C8 (no functions yet), C11 (permissions ready) | E1, E2, E4, E5, E6, E8 (baseline expectation) | C2, C14 (hover actions + inline edit designed) |
| Reactions | C8 (no reaction code exists), C12 (envelope pattern ready) | E1, E3, E7, E9, E10 (engagement/retention data) | C3, C14 (reaction bar + emoji picker designed) |
| Channel Members/Pins | C8 (no pin functions), C11 (permissions support manage_channel) | E1, E11, E13 (standard workspace features) | C5 (full spec with modals, permissions, header) |

---

## 6. Knowledge Gaps

### Documented Gaps

| Gap | What Was Searched | Why Insufficient | Impact on Recommendations |
|-----|-------------------|-----------------|--------------------------|
| `deleted_at` migration | Searched migrations directory and `message.ex` | `deleted_at` does not exist in schema. `edited_at` exists. | Adds ~1 hour to Rank 1 effort. Already accounted for in estimate. LOW. |
| ChannelServer edit/delete handling | Searched `channel_server.ex` for edit/delete | No edit or delete `handle_call` clauses exist. Messages in pending write queue need in-memory update. | Moderate complexity for Rank 1. MEDIUM. |
| `emoji-mart` current version | Not verified against npm registry | Spec references ~5.6 but current version may differ | If API changed, JS hook may need adjustments for Rank 2. LOW. |
| Specs README staleness | `specs/README.md` shows test count 495 and Step 4 "Not started" | README was not updated after recent feature completions | Does not affect recommendations, but should be updated. LOW. |
| Thread panel layout complexity | Reviewed spec and UX research | No precedent in codebase for sliding side panel alongside main content | Reinforces decision to defer threads. If threads were Rank 3, this would be MEDIUM risk. Currently N/A. |
| Phoenix Presence vs OnlineTracker | Both exist in supervision tree | Resolved in profiles implementation: OnlineTracker is the primary mechanism, Phoenix.Presence is legacy. | N/A for current recommendations. |

### Searches That Returned No Results

- No `edit_message` or `delete_message` functions in any context module
- No `MessageReaction` schema or `message_reactions` table
- No `PinnedMessage` schema or `pinned_messages` table
- No `InviteLink` schema or `invite_links` table
- No `parent_message_id` in Message schema (threads not started)
- No TODO/FIXME/HACK/PLACEHOLDER comments in `.ex` files

---

## Summary

| Rank | Feature | Composite Score | Confidence | Estimated Effort |
|------|---------|----------------|------------|-----------------|
| 1 | Message Editing & Deletion | **8.15** | HIGH | 12-16 hours |
| 2 | Reactions | **6.85** | HIGH | 16-20 hours |
| 3 | Channel Members & Pinned Messages | **6.60** | HIGH | 14-18 hours |

Combined estimated effort: 42-54 hours across all three features. Each feature builds on patterns established by the previous one, reducing integration risk. The recommended sequence maximizes value delivery per unit of effort while establishing reusable UI and backend patterns.

---

*Research produced by Nova. All major claims are supported by 3+ independent evidence sources. Knowledge gaps are documented with search methodology and impact assessment. This document supersedes v1 from earlier today -- the primary change is removing User Profiles (now complete) from the rankings and adding Channel Members/Pinned Messages as a new Rank 3 candidate.*
