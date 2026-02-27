# DM Safety System Design Validation Research

**Date:** 2026-02-27
**Researcher:** Nova (nw-researcher)
**Design Under Review:** `docs/plans/2026-02-27-dm-safety-system-design.md`
**Implementation Plan:** `docs/plans/2026-02-27-dm-safety-phase1-plan.md`
**Research Depth:** Detailed
**Sources Consulted:** 30+

---

## Table of Contents

1. [DM Request/Accept Flow Patterns](#1-dm-requestaccept-flow-patterns)
2. [Graduated Enforcement](#2-graduated-enforcement)
3. [Trust Scoring Systems](#3-trust-scoring-systems)
4. [Content Preview Safety](#4-content-preview-safety)
5. [Blocking Architecture](#5-blocking-architecture)
6. [Reporting and Auto-Moderation](#6-reporting-and-auto-moderation)
7. [Privacy Controls](#7-privacy-controls)
8. [Gaps and Risks](#8-gaps-and-risks)
9. [Summary of Recommendations](#9-summary-of-recommendations)
10. [Knowledge Gaps](#10-knowledge-gaps)
11. [Sources](#11-sources)

---

## 1. DM Request/Accept Flow Patterns

### What Our Design Proposes

- First-time DMs create a `dm_request` with status `pending`
- Recipient sees a "Message Requests" sidebar section with sender avatar, display name, sanitized preview (100 chars), and shared channel badges
- Actions: Accept, Decline, Block, Report
- Sender is never notified of decline (request appears "pending" forever)
- Accept creates or links a `dm_conversation` and delivers the original message

### What Industry Evidence Says

**Discord Message Requests** (closest parallel to our design):
Discord filters DMs from non-friends into a separate "Message Requests" folder. Recipients can preview the message and choose to accept (checkmark) or deny (X). On acceptance, the conversation moves to the top of the DM list. On denial, the request disappears and the sender is never notified. Per-server and global toggles let users control whether server members can DM them at all. [Source: Discord Support - Message Requests; n3tc0rd.digitalpress.blog]

**Instagram DM Requests:**
Messages from non-followers land in a "Message Requests" folder rather than the main inbox. Users can Accept or Delete. Instagram does not inform the sender whether their message was seen or declined. Recent updates added Sort & Filter capabilities for the requests folder. Instagram also layers a "Hidden Words" filter that automatically quarantines requests containing offensive words, phrases, or emojis into a separate hidden sub-folder with content covered by default. [Source: Instagram Help Center - Manage message requests; Croma Unboxed; Instagram Blog - Introducing new tools]

**Slack Connect DMs:**
For cross-organization DMs, Slack requires an invitation flow. The recipient reviews the invitation details (sender email, organization) and explicitly accepts before messaging begins. Admins can restrict invitations to verified organizations only. This is consent-gated but operates at the organization trust level rather than per-user. [Source: Slack Help - Manage settings for Slack Connect DMs; Slack Help - Use Slack Connect to start a DM]

**Twitter/X DMs:**
Users choose between "People you follow" (default) or "Everyone" for who can DM them. When open, messages from non-followed accounts go to a "Message Requests" folder with a quality filter that auto-segregates low-quality/spam messages. [Source: TweetFull; SocialBee; Social Media Today]

**LinkedIn InMail:**
Non-connected users cannot message for free at all. InMail (a premium feature) allows first-contact messaging, creating a monetary gate on cold outreach. Connection requests serve as the free consent mechanism. [Source: LinkedIn Help - InMail Messages; Evaboot]

### Confidence: HIGH (5 independent platform implementations confirm the pattern)

### Challenges and Improvements to Consider

1. **Our design aligns well with industry consensus.** The request/accept pattern with silent decline is used by Discord, Instagram, Twitter/X, and LinkedIn. This is a proven, well-understood pattern.

2. **Consider a "Hidden Requests" sub-folder.** Instagram's two-tier system (visible requests + hidden offensive requests) is more sophisticated than a single list. Our design could benefit from a similar approach where requests flagged by content heuristics are quarantined separately, reducing exposure to harmful content even in the preview stage.

3. **Sort and filter capabilities.** Instagram recently added Sort & Filter to message requests. As request volume grows, this will become necessary. Consider designing the `dm_requests` query to support filtering by shared channels, recency, and sender reputation.

4. **Shared context display is strong.** Our "shared channel badges" feature mirrors Discord's approach of showing shared servers. This is a well-validated trust signal that helps recipients make informed decisions.

5. **Consider showing mutual connections.** Beyond shared channels, showing "3 people you follow also follow this user" (Instagram-style) or "Also known in #channel" could strengthen the trust signal.

---

## 2. Graduated Enforcement

### What Our Design Proposes

Per sender-recipient pair on decline:
- Strike 1: 7-day cooldown (cannot re-request this recipient)
- Strike 2: 30-day cooldown
- Strike 3: Auto-block (permanent by this recipient)

Global thresholds:
- `block_count >= 5` distinct users --> `dm_restricted = true`
- `report_count >= 3` distinct users --> `dm_restricted = true`
- `report_count >= 5` distinct users --> flag for admin review

### What Industry Evidence Says

**Xbox Enforcement Strike System** (most detailed public graduated system):
Xbox uses an 8-strike system where violation severity determines how many strikes are assigned. Strikes expire after 6 months. Escalation: 2 strikes = 1-day suspension, 4 strikes = 7-day suspension, 8 strikes = 1-year suspension from social features. Permanent bans are reserved for "especially severe or egregious" violations and bypass the strike system entirely. Players can view their enforcement history and appeal eligible actions. [Source: Xbox Wire; Engadget; Pure Xbox]

**Academic Research on Escalation:**
Research on online harassment identifies a "Continuous Narrative Escalation" (CNE) model with three phases: target introduction, network decision, and network response. Escalation accelerates when new information is repeatedly added to an existing narrative. This suggests that enforcement should account for escalation velocity, not just absolute counts. [Source: ACM - "Stoking the Flames: Understanding Escalation in an Online Harassment Community"]

**PEN America Recommendations:**
PEN America advocates for automatic detection and quarantining of abusive content, with user agency over what to do with it. Their "shield" concept proactively filters abuse across feeds, DMs, and notifications. They recommend an "SOS button" that instantly activates tighter protections when a user is under siege. [Source: PEN America - "Treating Online Abuse Like Spam"; PEN America - "Shielding Users From Online Abuse"]

**DTSP Framework:**
The Digital Trust & Safety Partnership recommends developing operational infrastructure for sorting reports and escalation paths for complex issues. They emphasize using model confidence levels to guide enforcement decisions and continuous improvement through quality assurance metrics. [Source: DTSP Best Practices Framework]

### Confidence: MEDIUM-HIGH (strong directional evidence, but specific threshold numbers are proprietary)

### Challenges and Improvements to Consider

1. **Our 3-strike per-pair model is reasonable but consider strike expiration.** Xbox's 6-month strike expiration is notable. Our design makes strikes permanent per-pair. Consider whether strikes should decay over time (e.g., 90 days for strike 1, 180 days for strike 2). A user who was declined once 2 years ago may have legitimate reason to re-contact.

2. **The global threshold of 5 blocks for DM restriction is a starting point.** No platform publishes exact thresholds, but 5 distinct users blocking you is a meaningful signal. However, consider scaling this with platform size. On a 100-user platform, 5 blocks is 5% of users. On a 10,000-user platform, it is 0.05%. A percentage-based or logarithmic threshold may be more appropriate as the platform scales.

3. **Consider velocity-based detection.** The academic CNE research suggests that the rate of negative signals matters, not just the count. A user who gets 3 blocks in 1 hour is a very different signal than 3 blocks over 6 months. Add a velocity check: "3+ negative signals (block/decline/report) within 24 hours --> immediate temporary DM restriction pending review."

4. **Add a cooldown escalation for global DM restriction.** When `dm_restricted = true`, define a clear path back. Xbox's model uses time-based restoration. Consider: first restriction = 7 days, second = 30 days, third = permanent until admin review.

5. **Consider separating "soft" signals (declines) from "hard" signals (blocks, reports).** Declines may happen for benign reasons (wrong person, bad timing). Blocks and reports are much stronger signals of problematic behavior. The global threshold formula could weight these differently: `(block_count * 3) + (report_count * 5) + (decline_count * 1) >= threshold`.

---

## 3. Trust Scoring Systems

### What Our Design Proposes

A `user_trust_scores` table with:
- `decline_count` (distinct users who have declined)
- `block_count` (distinct users who have blocked)
- `report_count` (distinct users who have reported)
- `dm_restricted` (boolean, auto-set when thresholds exceeded)
- `dm_restricted_at` (timestamp)

Unblocking does NOT decrement trust scores (non-reversible reputation impact).

### What Industry Evidence Says

**Reputation System Design Principles:**
Academic literature identifies several core vulnerabilities in reputation systems: self-promoting (boosting own score), slandering (unfairly damaging others), denial of service, collusion (rings of users promoting each other), and Sybil attacks (creating multiple fake identities). Many attacks originate from collusion and Sybil attacks. [Source: ScienceDirect - Reputation Score; Wikipedia - Reputation system]

**Gaming and Manipulation:**
Unscrupulous users can form "rings" to manipulate reputation scores. Such fraud typically exhibits unusual gain or loss in scores within short time periods. Filtering dishonest feedback is achieved through multivariate outlier detection, majority voting to eliminate false reports, and weighting feedback according to recommender credibility. [Source: ACM - Reputation Gaming in Crowd Technical Knowledge Sharing; ScienceDirect - User Reputation]

**Transparency vs. Gaming Trade-off:**
If the exact evaluation formula is revealed, it may cause behavior that undermines the formula's effectiveness, creating a cat-and-mouse game. However, excessive opacity erodes user trust. The recommendation is to publish the general principles of the system without revealing exact thresholds or weights. [Source: Cambridge University Press - Reputation, Feedback, and Trust in Online Platforms]

**False Positive Mitigation:**
To address false positives: use risk-tiering and human review for high-impact actions, require multiple signals before enforcement, continuously measure precision at action thresholds, provide appeal pathways, and log evidence for audits. [Source: Springer - Interactive Reputation Systems; DTSP Best Practices]

**Content Moderation Quality:**
The TSPA recommends measuring both true positive rate (correctly identified violations) and false positive rate (legitimate content incorrectly flagged), noting that false positives can erode trust as much as failing to catch actual violations. [Source: TSPA - Content Moderation Quality Assurance; TSPA - Metrics for Content Moderation]

### Confidence: HIGH (well-studied academic domain with consistent findings)

### Challenges and Improvements to Consider

1. **The current design is vulnerable to weaponized reporting.** Three coordinated users filing reports could trigger `dm_restricted = true` for an innocent user. Add a "reporter credibility" weight: reports from users with their own poor trust scores should carry less weight. Consider: `effective_report_count = SUM(reporter_credibility_weight * 1)`.

2. **Add temporal decay.** Trust scores that only go up (never decay) create a "permanent scarlet letter" problem. Consider a rolling window: only count signals from the last 6-12 months toward threshold calculations, while retaining the full history for admin review.

3. **Missing: positive signals.** The current design only tracks negative signals. Consider adding positive trust indicators: account age, number of accepted DMs, number of messages exchanged in accepted conversations, channel participation history. A user with 50 accepted conversations and 1 block is very different from a user with 0 accepted conversations and 1 block.

4. **Missing: rate-of-change detection.** As noted in the reputation gaming literature, sudden changes in score are a strong fraud signal. Track the velocity of trust score changes and flag anomalies for review.

5. **Non-reversible scores are partially correct.** The design correctly states that unblocking does not decrement trust scores. This prevents "block-unblock" manipulation. However, consider adding an admin override capability to reset scores after investigation, and a natural decay mechanism for older signals.

6. **Consider the Sybil attack vector.** Multiple fake accounts could be created to inflate someone's block/report count. Without account-age or email-verification requirements, the trust scoring system is vulnerable. See Section 8 (Gaps and Risks) for mitigation strategies.

---

## 4. Content Preview Safety

### What Our Design Proposes

- `preview_text`: 500-char field in `dm_requests`, sanitized text-only, truncated first message
- Recipients see 100 chars of the preview in the sidebar
- No images, no rendered links in the preview

### What Industry Evidence Says

**Instagram Hidden Words:**
Instagram automatically filters DM requests containing offensive words, phrases, and emojis using a predefined list developed with anti-discrimination and anti-bullying organizations. Users can also create custom block lists. Filtered messages are quarantined in a separate hidden folder with content covered (blurred) by default -- users must explicitly tap to reveal. Critically, all filtering happens on-device; message content is not sent back to Instagram's servers for this purpose, preserving privacy. [Source: Instagram Blog - Introducing new tools to protect our community; Instagram Help - Limit sensitive content]

**Instagram Sensitive Content Control:**
A broader system allows users to choose how much potentially upsetting content they see across Explore, Search, and Recommendations. Users under 18 are locked out of the "More" option. This provides graduated exposure control. [Source: Instagram Help - About Sensitive Content Control; Facebook Blog]

**Discord Safer Messaging:**
Discord scans attachments and links in DMs using safety systems. Suspicious links trigger warnings before users can click through. Image scanning can flag explicit content before it reaches the user. [Source: Discord Support - Safer Messaging on Discord]

**PEN America Shield Concept:**
PEN America recommends proactively identifying abusive content in DMs and filtering it out before it reaches the user's primary view, quarantining it in a dashboard where users decide what to do with it. The design should be trauma-informed, reducing unwanted exposure to harmful content. [Source: PEN America - Shielding Users From Online Abuse]

### Confidence: HIGH (multiple platforms demonstrate layered preview safety)

### Challenges and Improvements to Consider

1. **Text-only sanitization is a good baseline, but consider keyword filtering.** Our design strips HTML/images but does not filter offensive text content in the preview. Instagram's "Hidden Words" approach demonstrates that text content itself can be harmful. Consider adding a configurable blocklist that quarantines requests containing known offensive terms, slurs, or phishing patterns (URLs, "click here", "urgent").

2. **Preview length of 100 chars in sidebar is appropriate.** Enough for context, short enough to limit exposure. The 500-char storage limit for the full preview is reasonable for the detail view.

3. **Consider a "covered by default" pattern.** Instagram covers filtered message content by default, requiring an explicit tap to reveal. For requests flagged by keyword filters, consider showing "[Message may contain sensitive content - tap to reveal]" instead of the raw preview text.

4. **URL detection and sanitization in preview text.** Even stripped of HTML, a preview containing `visit evil-site.com for free stuff` is harmful. Consider detecting and redacting or defanging URLs in preview text (e.g., `evil-site[.]com`).

5. **Missing: image handling for future phases.** The current design is text-only, which is appropriate for Phase 2. For future phases that may support image DMs, plan for: image blurring by default in requests, opt-in reveal, and automated image classification (NSFW detection).

6. **On-device vs. server-side filtering trade-off.** Instagram's on-device filtering preserves privacy but limits the platform's ability to learn from blocked content. For a server-rendered LiveView application, filtering will necessarily happen server-side. Document this privacy trade-off and ensure filtered content is not logged beyond what is needed for moderation.

---

## 5. Blocking Architecture

### What Our Design Proposes

- Bidirectional enforcement: `find_or_create_dm` checks blocks in both directions
- Blocker's effects: DM conversation hidden from sidebar (not deleted), pending requests auto-declined, blocked user hidden from search, online status hidden
- Blocked user is never notified
- Evidence preservation: messages and metadata retained, never deleted on block
- Unblock available from future "Blocked users" settings page
- Trust scores are not decremented on unblock

### What Industry Evidence Says

**Discord Blocking:**
Discord hides blocked users' messages behind a "Show message" toggle rather than deleting them. Blocked users can still see the blocker's messages in shared servers and determine online status. This incomplete blocking has been widely criticized by users as inadequate. Many users request truly hidden messages rather than the current spoiler-tag-like behavior. Blocked users can still ping the blocker's username (though no notification is generated). [Source: Discord Support - Blocking & Privacy Settings; Discord Community Posts; AirDroid]

**WhatsApp Blocking:**
Blocking does not delete existing messages or shared media on either side. New messages from the blocked user are never delivered (not even after unblocking). The blocked user sees one checkmark (sent) but never two (delivered). No "blocked" notification is sent. [Source: WhatsApp Help Center; TechUntold; Guiding Tech]

**Signal Blocking:**
Blocked users' messages are silently dropped. Existing conversation history is preserved on both sides. Messages sent while blocked are permanently lost (never delivered, even after unblocking). In shared groups, the blocker does not see the blocked user's messages. [Source: Signal Support - Block numbers, usernames or groups]

**Telegram Blocking:**
Existing conversations are preserved. The blocked user can see previous messages but cannot send new ones. Blocked users see "last seen a long time ago" instead of actual status. In groups, blocked users' messages remain visible (a known user complaint). [Source: Telegram Bug Reports; LemCRM]

**Cross-Platform Consensus on Bidirectional Enforcement:**
All major platforms implement unidirectional blocking (the blocker controls the block), but enforce communication prevention bidirectionally (neither party can initiate new contact). Our design's approach of checking both directions in `find_or_create_dm` aligns with this consensus.

### Confidence: HIGH (6 platform implementations provide clear consensus)

### Challenges and Improvements to Consider

1. **Bidirectional enforcement is correct and standard.** Our design matches industry consensus. Neither party should be able to initiate new DMs after a block.

2. **Evidence preservation is correct.** All major platforms preserve message history after blocking. Deleting messages would destroy evidence needed for moderation and could confuse the user's own conversation history.

3. **Consider message visibility after blocking.** Our design hides the DM conversation from the blocker's sidebar but does not specify what happens if the blocker navigates to the conversation directly. Discord's approach (messages visible but behind a toggle) has been criticized. Consider: conversation is removed from sidebar and inaccessible to the blocker unless they unblock first, while remaining in the database for admin/moderation purposes.

4. **The blocked user experience needs specification.** Our design says "blocked user is never notified," which is correct. But what does the blocked user see when they try to send a DM? The design says `"Cannot message this user"` for blocked senders. Consider making this message indistinguishable from the `dm_preference = "nobody"` message to avoid revealing that a block occurred. Use a generic message like "This user is not accepting messages" for both cases.

5. **Missing: behavior in shared channels.** If User A blocks User B, should User B's channel messages still be visible to User A? Most platforms (Discord, Telegram) still show blocked users' messages in shared spaces, which users find inadequate. For a Slack-like platform, channel messages should likely remain visible (hiding them breaks conversation context), but consider: muting blocked users' messages in channels with a "Show message" toggle (Discord-style) or leaving channel behavior unchanged (simpler, less controversial).

6. **Unblocking should not re-create the DM conversation.** On unblock, the old conversation should remain hidden until explicitly re-initiated. Do not auto-restore the sidebar entry.

---

## 6. Reporting and Auto-Moderation

### What Our Design Proposes

- Report categories: spam, harassment, inappropriate content, phishing, other
- Auto-block on report (reporter blocks reported user automatically)
- IP metadata capture (reporter IP, reported user IP, user agent, registration IP)
- Auto-escalation: `report_count >= 3` distinct users --> DM restricted
- Admin flag: `report_count >= 5` distinct users
- `abuse_reports` table with `status`: open, reviewed, actioned, dismissed

### What Industry Evidence Says

**DTSP Best Practices:**
The DTSP framework recommends developing operational infrastructure for sorting reports and escalation paths for complex issues. They emphasize using confidence levels to guide enforcement decisions and continuous review of enforcement quality through true positive and false positive rate measurement. [Source: DTSP Best Practices Framework; DTSP Safe Framework]

**Trust & Safety Operational Standards:**
T&S teams that rely heavily on automated enforcement can issue consequences based on false positives, and blocking/banning innocent users can erode trust as much as exposing them to offensive content. User reports can be influenced by altering the reporting process -- for example, adding friction (requiring more detail) reduces volume but improves signal quality. [Source: TSPA - Content Moderation Quality Assurance; TSPA - Metrics for Content Moderation]

**Weaponized Reporting Risk:**
Coordinated reporting attacks are a known vector where groups of users file simultaneous reports against a target to trigger automated enforcement. Platforms must distinguish between organic reports (independent users reporting at different times about different issues) and coordinated campaigns (multiple reports within a short window about the same target). [Source: Checkstep - What is Trust and Safety; ActiveFence; Unit21]

**Bluesky Transparency Data:**
Bluesky's 2025 Transparency Report provides one of the few public datasets on moderation volumes, though it does not publish specific threshold numbers. The trend across platforms is toward greater transparency about moderation volumes and outcomes. [Source: Bluesky 2025 Transparency Report]

### Confidence: MEDIUM (directional evidence is strong, but specific thresholds are proprietary across all platforms)

### Challenges and Improvements to Consider

1. **The threshold of 3 reports for DM restriction is aggressive and vulnerable to abuse.** Three coordinated users can weaponize this. Mitigations:
   - Require reports from accounts older than N days (e.g., 7 days)
   - Weight reports by reporter trust score
   - Add a time-spread requirement: 3 reports from 3 different 24-hour periods
   - Consider 5 as the restriction threshold and 3 as a "review queue" threshold

2. **Auto-block on report is correct but should be bidirectional.** When User A reports User B, both should be blocked from contacting each other. Our design creates a `user_blocks` row, which is good. Ensure the block is blocker_id=reporter, blocked_id=reported, and that `find_or_create_dm` checks both directions.

3. **Report categories are solid but consider adding sub-categories.** "Harassment" is broad. Consider structured sub-categories: threats, sexual harassment, hate speech, doxxing. This helps prioritize review (threats should be reviewed faster than spam) and provides better data for trend analysis.

4. **Missing: report de-duplication.** Can User A report User B multiple times? The design should enforce one open report per reporter-reported pair, or at minimum, only count distinct reporters toward thresholds. The `user_trust_scores.report_count` tracks distinct users, which is correct. Ensure `abuse_reports` allows multiple rows but thresholds only count distinct reporters.

5. **Missing: reporter feedback loop.** Platforms that notify reporters of outcomes ("We took action on your report") see higher future reporting rates and user satisfaction. Consider adding a `reporter_notified_at` field and a mechanism to notify reporters when their report is actioned.

6. **IP metadata capture is valuable but has limitations.** VPN and proxy usage make IP-based identification unreliable for determined bad actors. Treat IP data as one signal among many, not a primary identifier. Consider also capturing: session duration patterns, message timing patterns, and device fingerprint hashes.

---

## 7. Privacy Controls

### What Our Design Proposes

- `dm_preference` field on users with three options:
  - `"anyone"` (default) -- any user can send DM requests
  - `"shared_channels"` -- only users sharing at least one channel subscription
  - `"nobody"` -- no DM requests accepted (unless existing accepted conversation)

### What Industry Evidence Says

**Discord Privacy Model:**
Discord offers a global toggle ("Allow direct messages from server members") plus per-server overrides. This is effectively "friends only" vs. "server members" granularity. Discord also has a separate "Who can send you a friend request" setting with options: Everyone, Friends of Friends, Server Members. The Message Requests feature adds another layer where non-friend DMs go to a filtered queue rather than being blocked outright. [Source: Discord Support - Blocking & Privacy Settings; Discord Support - Message Requests]

**Twitter/X Privacy Model:**
Binary choice: "People you follow" or "Everyone." When set to "Everyone," non-followed users' messages go to a filtered "Message Requests" inbox with automated quality filtering. [Source: TweetFull; Comparitech; SocialBee]

**Instagram Privacy Model:**
Messages from non-followers automatically go to Message Requests (not a toggle -- this is default behavior). Instagram's Hidden Words feature adds content-based filtering within requests. Users under 18 have additional restrictions automatically applied. [Source: Instagram Help Center; AirDroid]

**LinkedIn Privacy Model:**
Monetary gate (InMail requires premium) combined with connection-based access. Free users can only message connections. This creates a natural friction barrier against spam. [Source: LinkedIn Help - InMail Messages; Evaboot]

**Slack Connect:**
Admin-controlled organization-level permissions combined with per-user acceptance. Admins can restrict DMs to verified organizations. Individual users must explicitly accept each invitation. [Source: Slack Help - Manage settings for Slack Connect DMs]

### Confidence: HIGH (5 platform implementations with clear patterns)

### Challenges and Improvements to Consider

1. **Three options are a good starting point but consider a fourth.** The current model is missing a "mutual follows" or "connections only" option. Discord's "Friends of Friends" concept could translate to: `"connections"` -- only users who have an existing accepted DM conversation or mutual channel membership. This is a softer version of `"shared_channels"` that accounts for past relationships.

2. **Consider per-channel DM visibility.** Discord's per-server DM toggle is powerful. For a Slack-like platform, allowing users to say "People from #engineering can DM me but not people from #random" adds useful granularity. This is listed in Phase 5 of the design but worth considering earlier.

3. **The default of `"anyone"` is debatable.** Discord defaults to allowing DMs from server members. Instagram defaults to allowing DMs from anyone but routing them to requests. Twitter defaults to "People you follow" (more restrictive). For a messaging platform, consider defaulting to `"shared_channels"` (the middle option) to provide safety-by-default while still enabling discovery. Users can opt into `"anyone"` if they choose.

4. **Missing: age-based defaults.** Discord recently implemented "teen-by-default settings" where users under 18 get more restrictive defaults, including restricted DM access from unknown users. If the platform ever supports age verification, consider age-based default overrides. [Source: Discord - Teen-by-default settings]

5. **Missing: temporary privacy escalation.** PEN America recommends an "SOS button" that instantly tightens protections when a user is under attack. Consider a "Do Not Disturb" mode that temporarily sets `dm_preference = "nobody"` and can be activated with one click, with automatic restoration after a configurable period.

6. **The `"shared_channels"` check needs careful implementation.** Ensure the check is performed at request time, not cached. A user leaving a shared channel should not retroactively invalidate an already-accepted conversation, but should prevent new requests.

---

## 8. Gaps and Risks

### What Our Design Proposes

The design mentions future work for IP-based ban evasion (Phase 5) and acknowledges the invite-only beta strategy as a deployment constraint.

### What Industry Evidence Says

**Rate Limiting on DM Requests:**
Instagram limits automated DMs to 200/hour via API and 20-50/day for new manual accounts. Twitter applies anti-spam timeouts requiring ~30-minute waits when patterns are detected. Slack limits API requests to specific methods. The consistent pattern: every platform applies rate limiting on message sending. [Source: CreatorFlow - Instagram API Rate Limits; BusinessHo - Twitter DM Limit; Slack API - Rate Limits]

**Account Creation Spam and Sybil Attacks:**
Attackers use commodity proxy services, VPNs, and residential botnets to distribute IP addresses, reducing the efficacy of IP-based rate limiting. Automated scripts use disposable email addresses from revolving pools to bypass email-based limits. CAPTCHAs are increasingly defeated by automated solvers. Account age and consistent participation history are among the more effective Sybil resistance mechanisms. [Source: Okta Blog; Group-IB; Wikipedia - Sybil attack; Loki Network]

**Cooldown Bypass:**
The primary cooldown bypass vector is creating new accounts. Without account-age restrictions on DM request capability, a blocked user can register a new account and immediately send new requests. [Source: Snyk Learn - No Rate Limiting; Medium - No Rate Limiting on Form]

### Confidence: HIGH (well-documented attack vectors with consistent evidence)

### Identified Gaps in Our Design

#### Gap 1: No Rate Limiting on DM Requests (CRITICAL)

**The problem:** Our design has no rate limit on how many DM requests a user can send per hour/day. A malicious user could spam hundreds of requests in minutes.

**Recommendation:** Add rate limiting at multiple levels:
- Per-sender: Maximum 10 pending DM requests at any time
- Per-sender per-hour: Maximum 5 new DM requests per hour
- Per-sender per-day: Maximum 20 new DM requests per day
- Implement as a module constant (extractable to config) consistent with the design's threshold pattern

#### Gap 2: No Account Age Restrictions (CRITICAL)

**The problem:** A user who is DM-restricted or blocked can create a new account and immediately resume sending DM requests. There is no "new account" friction.

**Recommendation:**
- Add an `account_age_minimum` threshold for DM request capability (e.g., 24 hours after registration)
- New accounts should only be able to DM users who share a channel with them for the first N days
- Consider requiring email verification before DM request capability is enabled
- Track `registration_ip` at signup for future ban evasion detection (already mentioned in Phase 5)

#### Gap 3: No Cooldown on DM Request After Decline (Recipient-Side)

**The problem:** When a recipient declines, the sender gets a 7-day cooldown for that specific recipient. But the sender can immediately send requests to other users. If a user is mass-sending requests and getting declined by many people, there is no mechanism to slow them down before they hit the global threshold.

**Recommendation:** Add progressive global cooldowns: after N declines within a rolling 24-hour window, impose a temporary global DM request cooldown. For example:
- 3 declines in 24 hours: 1-hour global cooldown
- 5 declines in 24 hours: 24-hour global cooldown
- This triggers before the global `dm_restricted` threshold and serves as an early warning

#### Gap 4: No Protection Against Coordinated Weaponized Reporting

**The problem:** Three coordinated users can file reports to trigger `dm_restricted = true` for an innocent user. The design has no defense against this.

**Recommendation:**
- Weight reports by reporter account age and trust score
- Require reports to come from accounts older than 7 days
- Add a time-spread requirement (reports must come from different 24-hour periods)
- Consider raising the auto-restriction threshold to 5 reports and making 3 reports a "review queue" trigger instead
- Add an appeal mechanism: restricted users can request admin review

#### Gap 5: No Abuse of the Request Preview System

**The problem:** The preview text field (500 chars) can be used to deliver a complete harassment message even if the request is never accepted. The recipient sees 100 chars in the sidebar, but the full 500-char preview is viewable in the request detail view.

**Recommendation:**
- Apply keyword filtering to preview text (see Section 4)
- Consider whether the preview needs to be 500 chars. Even 100 chars can deliver a harmful message.
- For flagged content, show a generic "This message may contain harmful content" instead of the actual text
- Log preview text for all declined/reported requests for pattern analysis

#### Gap 6: No Self-DM Rate Limiting Consideration

**The problem:** The Phase 1 plan references self-DMs (for personal notes). Ensure rate limiting and trust scoring exclude self-DM operations to avoid false signals.

**Recommendation:** Explicitly exclude `sender_id == recipient_id` from all trust score calculations, rate limiting, and request flows.

#### Gap 7: Missing Expiration for Pending Requests

**The problem:** DM requests with `status = "pending"` live forever. Over time, a user could accumulate thousands of pending requests that never get responded to.

**Recommendation:**
- Auto-expire pending requests after 30 days (set status to `"expired"`)
- Expired requests should not count as declines (no trust score impact)
- The sender should be able to re-request after expiration (with standard rate limits)
- Add an index on `(status, inserted_at)` to support efficient expiration queries

#### Gap 8: No Audit Trail for Trust Score Changes

**The problem:** The `user_trust_scores` table tracks current counts but not the history of changes. If an admin needs to investigate why a user was restricted, they must piece together information from `user_blocks`, `abuse_reports`, and `dm_requests` separately.

**Recommendation:** Consider adding a `trust_score_events` table or a JSONB audit log field that records each change with timestamp, trigger event, and source. This supports admin review and debugging.

---

## 9. Summary of Recommendations

### Immediate (Phase 1-2 Changes)

| # | Recommendation | Severity | Section |
|---|---------------|----------|---------|
| 1 | Add rate limiting on DM requests (10 pending, 5/hour, 20/day) | CRITICAL | 8.1 |
| 2 | Add account age minimum for DM requests (24 hours) | CRITICAL | 8.2 |
| 3 | Add velocity-based global cooldown (3 declines in 24h = cooldown) | HIGH | 8.3 |
| 4 | Apply keyword filtering to preview text | HIGH | 4 |
| 5 | Add pending request expiration (30 days) | MEDIUM | 8.7 |
| 6 | Make block/preference error messages indistinguishable | MEDIUM | 5 |
| 7 | Exclude self-DMs from trust scoring | LOW | 8.6 |

### Design Refinements (Phase 2-3 Changes)

| # | Recommendation | Severity | Section |
|---|---------------|----------|---------|
| 8 | Weight reports by reporter credibility (account age, trust score) | HIGH | 6 |
| 9 | Add time-spread requirement for report auto-escalation | HIGH | 6 |
| 10 | Add positive trust signals (accepted DMs, account age, participation) | MEDIUM | 3 |
| 11 | Add temporal decay to trust scores (rolling 6-12 month window) | MEDIUM | 3 |
| 12 | Consider per-pair strike expiration (90/180 days) | MEDIUM | 2 |
| 13 | Add reporter feedback loop (notify of action taken) | LOW | 6 |

### Strategic (Phase 4-5 Changes)

| # | Recommendation | Severity | Section |
|---|---------------|----------|---------|
| 14 | Implement "Hidden Requests" sub-folder for flagged content | MEDIUM | 1, 4 |
| 15 | Add "Do Not Disturb" temporary privacy escalation | MEDIUM | 7 |
| 16 | Consider defaulting `dm_preference` to `"shared_channels"` | MEDIUM | 7 |
| 17 | Add trust score audit trail / event log | LOW | 8.8 |
| 18 | Add weighted trust score formula instead of simple counts | LOW | 2 |

---

## 10. Knowledge Gaps

The following areas were researched but could not be adequately sourced:

### Gap A: Exact Auto-Escalation Thresholds Used by Major Platforms
**What was searched:** Specific numerical thresholds for report-based auto-restriction across Slack, Discord, Instagram, Twitter/X, LinkedIn.
**Why insufficient:** All platforms treat these as proprietary operational details. No platform publishes exact thresholds. The DTSP framework recommends having them but does not prescribe numbers.
**Impact on our design:** Our thresholds (3 reports = restrict, 5 = admin flag) are reasonable starting points but should be treated as configurable and tuned based on operational data.

### Gap B: Long-Term Effectiveness of Strike Expiration Periods
**What was searched:** Research on optimal strike expiration durations and their impact on recidivism.
**Why insufficient:** Xbox's 6-month expiration is the only public data point. No academic research was found comparing different expiration periods for messaging platform enforcement specifically.
**Impact on our design:** Our per-pair strikes are currently permanent. The recommendation to add expiration is based on the Xbox precedent and general principles, not strong comparative evidence.

### Gap C: False Positive Rates for Automated Trust Score Systems
**What was searched:** Measured false positive rates for trust/reputation scoring systems in messaging platforms.
**Why insufficient:** Platforms do not publish these metrics. Academic papers discuss the concept but not operational measurements from production messaging systems.
**Impact on our design:** We recommend adding appeal mechanisms and admin override capabilities as mitigation, but cannot quantify the expected false positive rate for our specific threshold configuration.

### Gap D: User Behavior Response to Silent Decline
**What was searched:** Research on how senders behave when DM requests appear permanently pending (the "never notified" pattern).
**Why insufficient:** While multiple platforms use this pattern, no research was found specifically measuring whether silent decline increases or decreases repeat contact attempts vs. explicit rejection.
**Impact on our design:** The silent decline pattern is industry standard, but its effectiveness as a deterrent is assumed rather than proven.

---

## 11. Sources

### Platform Documentation
1. [Discord Support - Message Requests](https://support.discord.com/hc/en-us/articles/7924992471191-Message-Requests)
2. [Discord Support - Blocking & Privacy Settings](https://support.discord.com/hc/en-us/articles/217916488-Blocking-Privacy-Settings)
3. [Discord Support - Safer Messaging on Discord](https://support.discord.com/hc/en-us/articles/115000068672-Safer-Messaging-on-Discord)
4. [Discord - Message Requests Explained (n3tc0rd)](https://n3tc0rd.digitalpress.blog/discord-message-requests-explained/)
5. [Instagram Help - Manage message requests](https://help.instagram.com/585369912141614)
6. [Instagram Blog - Introducing new tools to protect our community](https://about.instagram.com/blog/announcements/introducing-new-tools-to-protect-our-community-from-abuse)
7. [Instagram Help - About Sensitive Content Control](https://help.instagram.com/1055538028699165)
8. [Instagram Help - Limit sensitive content](https://help.instagram.com/251027992727268)
9. [Slack Help - Manage settings for Slack Connect DMs](https://slack.com/help/articles/360060326994-Manage-settings-and-permissions-for-Slack-Connect-direct-messages)
10. [Slack Help - Use Slack Connect to start a DM](https://slack.com/help/articles/1500001422062-Use-Slack-Connect-to-start-a-DM-with-someone-at-another-company)
11. [Slack API - Rate Limits](https://api.slack.com/docs/rate-limits)
12. [LinkedIn Help - InMail Messages](https://www.linkedin.com/help/linkedin/answer/a543895)
13. [Twitter/X DM Guide (TweetFull)](https://tweetfull.com/blog/twitter-dm-how-to-send-direct-messages-on-twitter-x-complete-guide/)
14. [Twitter DM Filtering (Social Media Today)](https://www.socialmediatoday.com/news/twitter-implements-new-dm-filtering-combat-spam-messages/687349/)
15. [WhatsApp Help - About reporting and blocking](https://faq.whatsapp.com/414631957536067/)
16. [Signal Support - Block numbers, usernames or groups](https://support.signal.org/hc/en-us/articles/360007060072-Block-numbers-usernames-or-groups)

### Enforcement and Strike Systems
17. [Xbox Wire - Enforcement Strike System](https://news.xbox.com/en-us/2023/08/15/xbox-enforcement-strike-system/)
18. [Xbox Support - Enforcement Strike System FAQ](https://support.xbox.com/en-US/help/family-online-safety/enforcement/enforcement-strike-system-faq)
19. [Engadget - Xbox adopts an eight-strike suspension policy](https://www.engadget.com/xbox-adopts-an-eight-strike-suspension-policy-153031666.html)

### Academic and Research Sources
20. [ACM - Stoking the Flames: Understanding Escalation in Online Harassment](https://dl.acm.org/doi/10.1145/3641015)
21. [ACM - Reputation Gaming in Crowd Technical Knowledge Sharing](https://dl.acm.org/doi/10.1145/3691627)
22. [ScienceDirect - Reputation Score](https://www.sciencedirect.com/topics/computer-science/reputation-score)
23. [ScienceDirect - User Reputation](https://www.sciencedirect.com/topics/computer-science/user-reputation)
24. [Cambridge University Press - Reputation, Feedback, and Trust in Online Platforms](https://www.cambridge.org/core/books/reengineering-the-sharing-economy/reputation-feedback-and-trust-in-online-platforms/6C1EB222CAE385076434293D2680EC13)
25. [Springer - Interactive Reputation Systems](https://link.springer.com/article/10.1007/s12599-017-0493-1)
26. [Wikipedia - Reputation system](https://en.wikipedia.org/wiki/Reputation_system)
27. [Wikipedia - Sybil attack](https://en.wikipedia.org/wiki/Sybil_attack)

### Trust & Safety Frameworks
28. [DTSP - Trust & Safety Best Practices Framework](https://dtspartnership.org/wp-content/uploads/2021/04/DTSP_Best_Practices.pdf)
29. [DTSP - Best Practices for AI and Automation in Trust & Safety (2024)](https://dtspartnership.org/wp-content/uploads/2024/09/DTSP_Best-Practices-for-AI-Automation-in-Trust-Safety.pdf)
30. [TSPA - Content Moderation Quality Assurance](https://www.tspa.org/curriculum/ts-fundamentals/content-moderation-and-operations/content-moderation-quality-assurance/)
31. [TSPA - Metrics for Content Moderation](https://www.tspa.org/curriculum/ts-fundamentals/content-moderation-and-operations/metrics-for-content-moderation/)
32. [PEN America - Treating Online Abuse Like Spam](https://pen.org/report/treating-online-abuse-like-spam/)
33. [PEN America - Shielding Users From Online Abuse](https://pen.org/shielding-users-from-online-abuse/)
34. [Bluesky 2025 Transparency Report](https://bsky.social/about/blog/01-29-2026-transparency-report-2025)

### Security and Attack Vectors
35. [Okta Blog - Opportunistic SMS pumping attacks](https://www.okta.com/blog/threat-intelligence/opportunistic-sms-pumping-attacks-target-customer-sign-up-pages/)
36. [Snyk Learn - No Rate Limiting](https://learn.snyk.io/lesson/no-rate-limiting/)
37. [CreatorFlow - Instagram API Rate Limits](https://creatorflow.so/blog/instagram-api-rate-limits-explained/)
38. [Loki Network - Preventing Sybil Attacks](https://loki.network/2018/07/05/preventing-sybil-attacks-runes-pow-and-captchas/)

### Platform Privacy and Age Controls
39. [Discord - Teen-by-default Settings](https://discord.com/press-releases/discord-launches-teen-by-default-settings-globally)
40. [Slack - Slack blocks public DM invite messages (Computerworld)](https://www.computerworld.com/article/1613359/slack-blocks-public-dm-invite-messages-after-backlash.html)
41. [TechCrunch - Slack's new DM feature Connect is opt-in](https://techcrunch.com/2021/03/24/slacks-new-dm-feature-connect-is-thankfully-opt-in/)
