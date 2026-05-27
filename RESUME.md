# RESUME — where to pick up

_Last updated: 2026-05-27 (Europe/London). A session-limit warning fired during the v0.9.16 deploy; this file is the continuity anchor._

## Just shipped — v0.9.16 (the Loom redesign)

- Tag `v0.9.16` pushed to `origin` → GitHub Actions deploy running. **Monitor:** https://github.com/d-j-will/slackex/actions
- The entire Loom redesign is behind the **`:loom_redesign`** flag (per-actor for chat: `enabled?(:loom_redesign, for: user)`; **global** for public pages landing/login/register: `enabled?(:loom_redesign)`).
- **CORRECTION (2026-05-27):** the flag is **ON in prod** (verified via `/admin/flags` — `:loom_redesign` Enabled in the prod toggles). The Loom redesign is **live for all prod users now**. The original "ships dark / OFF in prod" assumption above was wrong; it was enabled in the prod DB at some point. The *flag itself* is not yet retired from code (cutover § Task 5.2 still outstanding).
- Two changes in this deploy are **NOT** flag-gated (intended, live for everyone): the **node-badge removal** and the **auth submit-button fix** (`btn btn-primary` restored on login/register).
- No migrations in this release (`Release.migrate` is a no-op).

**To dogfood Loom in prod:** `/admin/flags` → `:loom_redesign` → enable for your actor. Then flip globally when happy. The "Loom becomes default" cutover tasks (remove flag conditionals, retire old daisyUI theme, **PWA chrome colors** — theme-color meta, manifest, offline page) are in `docs/superpowers/plans/2026-05-26-loom-redesign.md` § Task 5.2.

**Dev note:** all 16 feature flags are currently enabled in the **dev** DB (so every surface is visible locally). Prod flag state is separate.

## Flag cleanup (#1) — CODE DONE (commit `61cb69a`, 2026-05-27); deploy + DB-row deletion pending

The 6 un-flag candidates were all verified **Enabled in prod**, so removing their gates is behavior-preserving. Surgery committed to master (gates green: format, credo, dialyzer, 1475 tests). Remaining work is **deploy-gated** — see "Next" at the bottom of this section.

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

**Next (DEPLOY-GATED — do not reorder):** prod still runs **v0.9.16**, whose code reads these flags via `enabled?`. So the `fun_with_flags_toggles` rows must **not** be deleted yet — deleting now would flip the 6 features **OFF** in the running prod. Correct order:
1. Tag a new version via `/deploy` so prod runs the flag-free code (`61cb69a`+).
2. **Then** delete the rows at `/admin/flags` for the 6 un-flagged flags **plus** the dead `show_cluster_node` (and `new_ui` if present — not in prod as of 2026-05-27).

Both steps are prod-affecting → get explicit go-ahead before each.

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
