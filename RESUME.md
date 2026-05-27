# RESUME — where to pick up

_Last updated: 2026-05-27 (Europe/London). A session-limit warning fired during the v0.9.16 deploy; this file is the continuity anchor._

## Just shipped — v0.9.16 (the Loom redesign)

- Tag `v0.9.16` pushed to `origin` → GitHub Actions deploy running. **Monitor:** https://github.com/d-j-will/slackex/actions
- The entire Loom redesign is behind the **`:loom_redesign`** flag (per-actor for chat: `enabled?(:loom_redesign, for: user)`; **global** for public pages landing/login/register: `enabled?(:loom_redesign)`).
- Flag is **OFF in prod** → ships dark; prod users keep the old UI until you enable it.
- Two changes in this deploy are **NOT** flag-gated (intended, live for everyone): the **node-badge removal** and the **auth submit-button fix** (`btn btn-primary` restored on login/register).
- No migrations in this release (`Release.migrate` is a no-op).

**To dogfood Loom in prod:** `/admin/flags` → `:loom_redesign` → enable for your actor. Then flip globally when happy. The "Loom becomes default" cutover tasks (remove flag conditionals, retire old daisyUI theme, **PWA chrome colors** — theme-color meta, manifest, offline page) are in `docs/superpowers/plans/2026-05-26-loom-redesign.md` § Task 5.2.

**Dev note:** all 16 feature flags are currently enabled in the **dev** DB (so every surface is visible locally). Prod flag state is separate.

## NEXT: Flag cleanup (#1 — needs one confirmation before code surgery)

Inventory + recommendation (acceptance = your prod-stability call):

**Dead — delete the DB row at `/admin/flags` (no code left):**
- `show_cluster_node` — node badge already removed from code this session; only the DB row remains.
- `new_ui` — ghost (no code refs, not even in dev DB); delete prod row if present.

**Un-flag candidates — mature core features (low risk; surgery = remove `enabled?` calls + `<%= if @flag %>` guards + assigns + `test_helper.exs` entries + flag-specific tests):**
- `reactions`, `threads`, `quick_switcher`, `channel_management`, `markdown_rendering`, `link_previews` — **safe to un-flag** (definitely live in prod, core chat).
- `message_search` — **hold**: prod uses `StubClient` for embeddings (CPU EXLA OOMs the LXC), so semantic search is degraded in prod; confirm the text-search path is acceptable before un-flagging.
- `channel_summarization` — **hold**: AI cost; keep as a switch unless you want it always-on.
- `catchup_on_reconnect` — borderline; could accept if stable.

**Keep flagged:** `loom_redesign` (active rollout), `incoming_webhooks` (Release-1 work outstanding), `dark_factory` (experimental), `push_notifications` (browser-dependent kill-switch), `website_analytics` + `exclude_from_analytics` (ops toggles).

**Blocked on:** your confirmation of the un-flag list (and ideally a prod flag-state check — offer stands to SSH `root@192.168.1.102` and dump prod FunWithFlags state). I did NOT start the surgery because it's multi-file + a prod-behaviour decision, and the session-limit risk made half-done surgery unwise.

## THEN: Sous — full brainstorm written, awaiting a scope decision

- Sous is **not** a re-skin — it's a whole product (work-item event stream + 7 role lenses + 8 surfaces + new schema). Same warm-charcoal/gold palette as Loom but **Instrument Serif upright (no italics)**.
- Full breakdown + recommended slicing: **`docs/feature/sous/sous-brainstorm.md`**.
- Design bundle extracted at `/tmp/sous-design/` (README at `tenun/project/design_handoff_sous/README.md`; prototypes in `…/design/src/`).
- Decision needed: which vertical slice to build first (the brainstorm recommends one).

## Loom follow-ups (deferred, lower priority)

- Deferred novel features: `docs/feature/loom-redesign/deferred-novel-features.md` (structured Summary citations is the high-value one).
- Visual polish to confirm on-device: swatch active-checkmark, seg-button contrast at lighter accents, mobile drawer, Appearance-panel scroll, PWA notch fill (see plan § Phase 5 checklist).

## Key context pointers
- Loom architecture + gotchas: memory `project_loom_redesign.md`; plan `docs/superpowers/plans/2026-05-26-loom-redesign.md`.
- **Core gotcha:** anything rendered outside a `.loom` ancestor won't theme (modals are wrapped separately).
- Loom layer: `assets/css/loom.css`; hooks `assets/js/hooks/{loom_prefs,appearance_panel,emoji_picker}.js`.
