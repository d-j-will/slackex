# RESUME — where to pick up

_Last updated: 2026-05-28 (Europe/London). Latest work: **Sous Slice B1 deployed as v0.9.21** — role-lens viewer model + per-(viewer, work_item) attention triage + Facet Drawer (no AI; per-role facet text deferred to B2). Behind `:sous` flag (off in prod). See the Sous section below. Slice A shipped earlier (v0.9.19 + v0.9.20). This file is the continuity anchor._

## Just shipped — v0.9.16 (the Loom redesign)

- Tag `v0.9.16` pushed to `origin` → GitHub Actions deploy running. **Monitor:** https://github.com/d-j-will/slackex/actions
- The entire Loom redesign is behind the **`:loom_redesign`** flag (per-actor for chat: `enabled?(:loom_redesign, for: user)`; **global** for public pages landing/login/register: `enabled?(:loom_redesign)`).
- **CORRECTION (2026-05-27):** the flag is **ON in prod** (verified via `/admin/flags` — `:loom_redesign` Enabled in the prod toggles). The Loom redesign is **live for all prod users now**. The original "ships dark / OFF in prod" assumption above was wrong; it was enabled in the prod DB at some point. The *flag itself* is not yet retired from code (cutover § Task 5.2 still outstanding).
- Two changes in this deploy are **NOT** flag-gated (intended, live for everyone): the **node-badge removal** and the **auth submit-button fix** (`btn btn-primary` restored on login/register).
- No migrations in this release (`Release.migrate` is a no-op).

**To dogfood Loom in prod:** `/admin/flags` → `:loom_redesign` → enable for your actor. Then flip globally when happy. The "Loom becomes default" cutover tasks (remove flag conditionals, retire old daisyUI theme, **PWA chrome colors** — theme-color meta, manifest, offline page) are in `docs/superpowers/plans/2026-05-26-loom-redesign.md` § Task 5.2.

**Dev note:** all 16 feature flags are currently enabled in the **dev** DB (so every surface is visible locally). Prod flag state is separate.

## Flag cleanup (#1) — ✅ COMPLETE (2026-05-27)

Fully shipped and verified end-to-end:
- Code un-flagged in `61cb69a` (6 features, −125 lines), deployed in **v0.9.17** (prod healthy, HTTP 200).
- Prod orphan rows deleted + verified: the 6 un-flagged flags, the dead `show_cluster_node`, and a stray `message_stream` row (accidentally created in the admin UI — no code ever referenced it).
- Prod `fun_with_flags_toggles` now holds exactly the 8 deliberately-flagged features: `catchup_on_reconnect`, `channel_summarization`, `dark_factory`, `incoming_webhooks`, `loom_redesign`, `message_search`, `push_notifications`, `website_analytics`. (`exclude_from_analytics` has no persisted row — defaults off — which is expected.)

Inventory (original recommendation kept for reference):

**Dead — delete the DB row at `/admin/flags` (no code left):**
- `show_cluster_node` — node badge already removed from code this session; only the DB row remains.
- `new_ui` — ghost (no code refs, not even in dev DB); delete prod row if present.

**Un-flag candidates — mature core features (low risk; surgery = remove `enabled?` calls + `<%= if @flag %>` guards + assigns + `test_helper.exs` entries + flag-specific tests):**
- ✅ **DONE** — `reactions`, `threads`, `quick_switcher`, `channel_management`, `markdown_rendering`, `link_previews` un-flagged in commit `61cb69a`. No code reads these flags anymore (assigns, template/component guards, prop-threading, test_helper entries, 2 flag-off tests, e2e scaffolding all removed). Net −125 lines.
- `message_search` — **hold**: prod uses `StubClient` for embeddings (CPU EXLA OOMs the LXC), so semantic search is degraded in prod; confirm the text-search path is acceptable before un-flagging.
- `channel_summarization` — **hold**: AI cost; keep as a switch unless you want it always-on.
- `catchup_on_reconnect` — borderline; could accept if stable.

**Keep flagged:** `loom_redesign` (active rollout), `incoming_webhooks` (Release-1 work outstanding), `dark_factory` (experimental), `push_notifications` (browser-dependent kill-switch), `website_analytics` + `exclude_from_analytics` (ops toggles).

**Done** — deploy-gated sequence executed correctly: deployed v0.9.17 (flag-free code) first, then deleted the prod rows. See the ✅ COMPLETE block at the top of this section.

**Lesson worth keeping:** un-flagging a feature is only safe to follow with DB-row deletion *after* the flag-free code is live in prod — otherwise the running (old) code reads the now-missing flag as disabled and the feature vanishes. Always: ship code → verify deployed → then delete toggle rows.

Both steps are prod-affecting → get explicit go-ahead before each.

## Sous — Slice A (event-stream tracer bullet) BUILT, not yet dogfooded/pushed (2026-05-27)

Decisions made: framing = **evolve Tenun behind a `:sous` flag** (not a new app); first slice = **A, the event-stream tracer bullet**; linkage = **Option Q** (ADR-002 — card posted via the existing Messaging facade, `WorkItem.card_message_id` set by a `:card_posted` event; **no** changes to the message write-behind hot path); attention seed = **`:act` only** (attention control deferred to Slice B).

**What's built** (19 commits on master, range `fb4dfa1..5f62509`, behind `:sous`):
- `Slackex.Sous` context: `WorkItem` + `Decision` + `WorkItemEvent` (append-only) + pure `Projection` reducer; `open_decision/1`, `post_decision_card/2`, `move/3`, `list_in_flight/0`, `card_messages_for_channel/1`.
- `/decide` slash command → modal → creates a `:decision` work item (state `:mise`) + posts a rich decision card to chat.
- **In Service** board LiveView at `/in-service` (four columns, attention treatments, per-card move buttons), flag-gated nav link.
- 7 event-sourcing invariants honored; replay-guard test folds `:created`+`:state_changed` across all fields. Mandatory e2e integration test exercises chat→work-item→board via the real facade. Suite: **1505 tests, 0 failures**. Final code review passed (I-1 card-render gating + I-2 replay-guard strengthened and fixed).

**State / how to pick up:**
- **B1 SHIPPED as v0.9.21 (2026-05-28)** — `Slackex.Sous.Viewer` (data-driven role-lenses, 7 seeded) + `Slackex.Sous.WorkItemFacet` (composite PK, lazy default `:watch`) + `:attention_set` event + `Sous.set_attention/4` command + `Slackex.Sous.ViewerPreference` encapsulated seam (LocalStorage default, InMemoryStore proves the swap). In Service board reshapes per the active viewer's attention (`act > watch > know`, hidden via `+N not at your altitude` toggle, newest-first within rank). Facet Drawer renders the same atom through each prism's attention pill with a 4-pill selector + three dismiss mechanisms. **Behind `:sous` (off in prod — flip at `/admin/flags` to dogfood in prod).** Browser-verified in dev (2026-05-28). New invariants #8–#11 in the spec (`docs/feature/sous/design/slice-b1-role-lens-and-facet-drawer.md`); plan + execution notes at `docs/superpowers/plans/2026-05-28-sous-slice-b1-role-lens.md`. Final review post-merge added 6 regression tests (sort order, drawer dismiss×3, pill direct-click, visual treatments). AI per-role facet text is deferred to **B2**.
- **SHIPPED**: deployed as **v0.9.19** (Slice A) and **v0.9.20** (thread-panel dup-id fix). Pushed to origin; both CI quality runs green.
- `:sous` is **ENABLED in the dev DB** (dogfooded 2026-05-27); still **OFF in prod** (no row). To turn Sous on in prod: `/admin/flags` → `:sous` → enable.
- **Engineering-process fixes this session** (worth knowing): (a) `scripts/pre-deploy` + the pre-commit hook were running `mix format` in the **dev** env while CI uses **`MIX_ENV=test`** — they disagreed on migration files (caused a v0.9.18 CI format failure). Both now run format under test env; `scripts/pre-deploy` was also rewritten to mirror CI's **full** quality job (it was a partial copy missing contract/e2e/hex.audit/deps.unlock). (b) Fixed a flaky `ThreadTest` "duplicate id" crash — thread-panel replies now use `id_prefix="thread-"` (matching the parent) so they don't collide with the same message in the main stream. Deterministic regression test added.
- **UI browser-verified in dev (2026-05-27):** `/decide` → modal → decision card (DRI/What/Why/Next + "lives in: In Service") → In Service board (4 columns, `:act` accent + "behind" on the Mise card) → move button transitions the card live. Spine confirmed end-to-end.
- **Cosmetic follow-up:** card title + board masthead render in serif *italic* (reused Loom styling). The Sous design wants **upright** Instrument Serif + `em { font-style: normal }` — the "Sous visual mode" was scoped out of Slice A (spec §4). Add to visual-polish/Slice B.
- Deferred to Slice B (per review): viewer model + per-viewer `WorkItemFacet` + AI facets; attention control (`:attention_set` event); concurrent-move row lock (M-1); `post_decision_card` logging in-context (M-2); reducer fallthrough clause (M-3). 5 credo `--strict` alias-order nits in Sous test files (project gate is non-strict).

**Key docs:** spec `docs/feature/sous/design/slice-a-event-stream-tracer-bullet.md`; ADR-001 (plaintext Decision fields), ADR-002 (write-behind reconciliation); plan `docs/superpowers/plans/2026-05-27-sous-slice-a-event-stream.md`; brainstorm `docs/feature/sous/sous-brainstorm.md`; handoff `docs/feature/sous/handoff/`.

## Loom follow-ups (deferred, lower priority)

- Deferred novel features: `docs/feature/loom-redesign/deferred-novel-features.md` (structured Summary citations is the high-value one).
- Visual polish to confirm on-device: swatch active-checkmark, seg-button contrast at lighter accents, mobile drawer, Appearance-panel scroll, PWA notch fill (see plan § Phase 5 checklist).

## Key context pointers
- Loom architecture + gotchas: memory `project_loom_redesign.md`; plan `docs/superpowers/plans/2026-05-26-loom-redesign.md`.
- **Core gotcha:** anything rendered outside a `.loom` ancestor won't theme (modals are wrapped separately).
- Loom layer: `assets/css/loom.css`; hooks `assets/js/hooks/{loom_prefs,appearance_panel,emoji_picker}.js`.
