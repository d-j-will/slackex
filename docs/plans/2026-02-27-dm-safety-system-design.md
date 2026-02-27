# DM Safety System Design

**Date:** 2026-02-27
**Status:** Approved
**Deployment prerequisite:** Invite-only / limited beta until Phase 3 is complete.

## Problem

Direct messages currently have two issues:
1. **Broken delivery:** When User A sends a DM to User B, User B's sidebar never updates — the conversation is invisible unless B refreshes the page.
2. **No safety controls:** Any user can send any content to any other user with no consent, blocking, or reporting mechanisms. This opens the door to spam, harassment, phishing, and inappropriate content.

## Design Principles

- **Consent before contact:** First-time DMs require recipient acceptance.
- **Safe previews:** Recipients see enough context to decide, but harmful content (images, rendered links) is never delivered without consent.
- **Graduated enforcement:** Repeated bad behavior escalates automatically (cooldown → block → DM restriction).
- **Silent enforcement:** Bad actors are never told they've been declined or blocked (prevents retaliation).
- **Evidence preservation:** Messages and metadata are retained for moderation, never deleted on block.
- **Extensible schema:** Tables and fields support future features (multi-tenant trust, IP-based ban evasion, admin dashboard) without schema rewrites.
- **Rate-limited by default:** DM requests are rate-limited to prevent spam floods before trust scores can react.
- **Account maturity gates:** New accounts face restrictions to counter Sybil attacks (create-ban-recreate cycles).

## Data Model

### New Tables

#### `user_blocks`
| Column | Type | Notes |
|--------|------|-------|
| `id` | bigint (PK) | Snowflake |
| `blocker_id` | references users | The user who blocked |
| `blocked_id` | references users | The user who was blocked |
| `reason` | string (nullable) | Optional reason for admin review |
| `inserted_at` | utc_datetime_usec | |

Unique constraint: `(blocker_id, blocked_id)`.

#### `dm_requests`
| Column | Type | Notes |
|--------|------|-------|
| `id` | bigint (PK) | Snowflake |
| `sender_id` | references users | Who initiated |
| `recipient_id` | references users | Who receives the request |
| `preview_text` | string (500 chars) | Sanitized, text-only, truncated first message |
| `status` | string | `pending`, `accepted`, `declined` |
| `dm_conversation_id` | references dm_conversations (nullable) | Set on accept |
| `inserted_at` | utc_datetime_usec | |
| `responded_at` | utc_datetime_usec (nullable) | When accepted/declined |

Unique partial constraint: `(sender_id, recipient_id)` where `status = 'pending'`.

#### `user_trust_scores`
| Column | Type | Notes |
|--------|------|-------|
| `id` | bigint (PK) | |
| `user_id` | references users | Unique |
| `decline_count` | integer, default 0 | Distinct users who have declined |
| `block_count` | integer, default 0 | Distinct users who have blocked |
| `report_count` | integer, default 0 | Distinct users who have reported |
| `dm_restricted` | boolean, default false | Auto-set when thresholds exceeded |
| `dm_restricted_at` | utc_datetime_usec (nullable) | |
| `updated_at` | utc_datetime_usec | |

#### `abuse_reports`
| Column | Type | Notes |
|--------|------|-------|
| `id` | bigint (PK) | Snowflake |
| `reporter_id` | references users | |
| `reported_user_id` | references users | |
| `category` | string | `spam`, `harassment`, `inappropriate_content`, `phishing`, `other` |
| `description` | text (nullable) | Reporter's description |
| `evidence_message_id` | references messages (nullable) | |
| `evidence_dm_request_id` | references dm_requests (nullable) | |
| `status` | string, default `open` | `open`, `reviewed`, `actioned`, `dismissed` |
| `admin_notes` | text (nullable) | For admin dashboard |
| `metadata` | jsonb | IP address, user agent, registration IP, etc. |
| `inserted_at` | utc_datetime_usec | |

### Modified Tables

#### `dm_conversations`
- Add `updated_at` (utc_datetime_usec) — tracks last message activity for sidebar ordering.

#### `users`
- Add `dm_preference` (string, default `"anyone"`) — `"anyone"`, `"shared_channels"`, `"nobody"`.

### Configurable Thresholds (module constants, extractable to config)

| Threshold | Default | Description |
|-----------|---------|-------------|
| Decline strike 1 cooldown | 7 days | Can't re-request this recipient |
| Decline strike 2 cooldown | 30 days | Extended cooldown |
| Decline strike 3 | Auto-block | Permanent block by this recipient |
| Global block threshold | 5 distinct users | `dm_restricted = true` |
| Global report threshold | 3 distinct users | `dm_restricted = true` |
| Report escalation threshold | 5 distinct users | Flag for admin review |
| DM request rate limit | 5/hour, 20/day | Per-sender cap on new DM requests |
| Max pending requests | 10 | Per-sender cap on unresolved pending requests |
| Account age for DM requests | 24 hours | Minimum account age to send DM requests |
| New account DM restriction | 7 days | Accounts < 7 days old restricted to shared-channel DMs only |

## DM Request/Accept Flow

### Initiation (User A → User B)

Pre-flight checks (in order):
1. Is User A's account < 24 hours old? → "Your account is too new to send DM requests"
2. Is User A blocked by User B? → "Cannot message this user"
3. Is User A's DM restricted? → "Your DM ability is suspended"
4. Has User A hit rate limits? (5/hour, 20/day, or 10 pending) → "You're sending too many requests. Please try later."
5. Is User A's account < 7 days old and they share no channels with B? → "New accounts can only DM users in shared channels"
6. Does User B's `dm_preference` allow contact from User A? → Check rules below
7. Is there an existing accepted DM conversation? → Send directly (no request needed)
8. Otherwise → Create `dm_request` with `status = "pending"`

### Privacy check (`dm_preference`)
- `"anyone"` → Allowed
- `"shared_channels"` → Allowed only if A and B share at least one channel subscription
- `"nobody"` → Blocked (unless existing accepted conversation)

### Recipient experience

Sidebar gains a "Message Requests" section:
- Shows pending requests with sender avatar, display name, sanitized preview (100 chars)
- Shows shared channel badges ("Also in #engineering, #general")
- Actions: **Accept**, **Decline**, **Block**, **Report**

### Accept
1. Create `dm_conversation` (or link to existing)
2. Update `dm_request.status = "accepted"`, set `dm_conversation_id`
3. Move conversation to "Direct Messages" sidebar section
4. Deliver original message into conversation
5. Open conversation view

### Decline
1. Update `dm_request.status = "declined"`, set `responded_at`
2. Apply graduated enforcement (per sender-recipient pair):
   - Strike 1: 7-day cooldown
   - Strike 2: 30-day cooldown
   - Strike 3: Auto-block
3. Increment `user_trust_scores.decline_count` (per distinct declining user)
4. Remove request from recipient sidebar
5. Sender is never notified (request appears "pending" forever from their view)

### Global trust enforcement
- `block_count >= 5` → `dm_restricted = true`
- `report_count >= 3` → `dm_restricted = true`
- `report_count >= 5` → flag for admin review (future)

## Blocking

### Entry points
1. DM request: Decline → Block
2. Active DM conversation: kebab menu → Block user
3. User profile (future extensibility)

### Effects
- Creates `user_blocks` row
- Active DM conversation hidden from blocker's sidebar (not deleted — preserves evidence)
- Pending DM requests auto-declined
- Blocked user can't: send DM requests, appear in user search, show online status to blocker
- Blocked user is never notified
- Increments `user_trust_scores.block_count`

### Unblocking
- Available from "Blocked users" list (future settings page)
- Removes `user_blocks` row
- Does NOT decrement trust scores (non-reversible reputation impact)

## Reporting

### Entry points
1. DM request: alongside Decline/Block
2. Message context menu in DM conversation
3. Channel message context menu (future)

### Flow
1. User clicks "Report"
2. Modal: category selection (spam, harassment, inappropriate content, phishing, other) + optional description
3. System auto-captures: offending message/request, timestamps, IP metadata
4. Creates `abuse_reports` row with `status = "open"`
5. Auto-blocks reported user
6. Increments `user_trust_scores.report_count`

### Metadata capture
```json
{
  "reporter_ip": "from conn.remote_ip / socket connect_info",
  "reported_user_ip": "from last known connection",
  "user_agent": "from conn/socket",
  "reported_user_registration_ip": "captured at signup (future)"
}
```

## PubSub Topics

| Topic | Events | Purpose |
|-------|--------|---------|
| `"dm:#{dm_id}"` | `message.new`, `typing` | Existing — messages within a conversation |
| `"user:#{user_id}"` | `dm_request.new` | Notify recipient of new DM request |
| `"user:#{user_id}"` | `dm_request.accepted` | Notify sender their request was accepted |
| `"user:#{user_id}"` | `dm_conversation.new` | Notify recipient when conversation is created (sidebar refresh) |

## Phased Delivery

### Phase 1: Fix DM Delivery + Foundation
- Fix sidebar notification bug (PubSub broadcast `dm_conversation.new` to recipient)
- Add `updated_at` to `dm_conversations`, update on each message
- Order sidebar DMs by `updated_at` instead of `inserted_at`
- Add `user_blocks` table + schema + context functions
- Block UI from DM conversation (kebab menu → Block)
- Block enforcement: filter blocked users from DM creation and user search
- Rate limit DM creation: max 5 new DMs/hour, 20/day per sender (reuses existing ChannelServer rate limiter pattern)

**Deliverable:** Cross-user DMs work. Users can block each other. Basic rate limiting prevents spam floods.

### Phase 2: DM Request/Accept Flow
- Add `dm_requests` table + schema
- Add `user_trust_scores` table + schema
- Change DM initiation: first contact creates `dm_request`
- Build "Message Requests" sidebar section with sanitized preview
- Accept/Decline UI with shared-channel context badges
- Graduated enforcement on decline (3-strike → auto-block)
- Global trust threshold: auto-restrict DM when `block_count >= 5`
- Real-time PubSub for DM requests
- DM request rate limits: max 10 pending, 5 new/hour, 20/day per sender
- Account age gate: < 24 hours → no DM requests; < 7 days → shared-channel DMs only

**Deliverable:** First contact requires consent. Repeat offenders face graduated enforcement. Sybil attack vector closed.

### Phase 3: Reporting & Trust Escalation
- Add `abuse_reports` table + schema
- Report modal with categories
- Auto-block on report
- IP metadata capture from socket/conn
- Auto-escalation: `report_count >= 3` → DM restricted

**Deliverable:** Users can report abuse. Serial offenders are auto-restricted.

### Phase 4: Privacy Controls & Admin Foundation
- Add `dm_preference` to users
- Privacy settings UI
- Shared-channel check in DM request flow
- "Blocked users" management page
- Basic admin view: list flagged users and open reports (read-only)

**Deliverable:** Users control who can contact them. Admins have visibility.

### Phase 5: Admin Dashboard & Ban Evasion (Future)
- Admin action capabilities (suspend, warn, clear reports)
- IP pattern detection for ban evasion
- Per-channel DM trust settings
- Audit log for admin actions

**Deliverable:** Production-grade moderation system.

## Deployment Strategy

- **Phases 1-3:** Invite-only beta with limited users. No public access.
- **Phase 4:** Open to wider beta once privacy controls and admin visibility exist.
- **Phase 5:** Production-ready for open registration.
