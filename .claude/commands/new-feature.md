Scaffold a new user-facing feature behind a FunWithFlags feature flag.

All new user-facing features must be invisible until PO-approved. This skill
ensures the flag is added in both the required locations and that nothing ships
exposed.

## Steps

1. **Confirm the feature name** if not already provided. Derive the flag atom:
   - Use snake_case: `:message_reactions`, `:threaded_replies`, `:invite_links`
   - One flag per feature — do not reuse an existing flag for new behaviour

2. **New context? Add `Boundary` enforcement.** If the feature introduces a new
   bounded context (a new `lib/slackex/<context>/<context>.ex` root module), that
   root module MUST declare its boundary so it cannot silently fall outside
   compile-time architectural enforcement:
   ```elixir
   defmodule Slackex.YourContext do
     use Boundary,
       deps: [Slackex.Accounts, Slackex.Infrastructure],  # only what it actually calls
       exports: [YourSchema, PublicSubModule]             # its narrow public surface

     # ...
   end
   ```
   - Keep `deps:` minimal — derive it from real call sites (`mix boundary.find_external_deps` helps).
   - `exports:` lists the schemas/sub-modules other contexts may reference; everything
     else stays private to the context.
   - There is **no project-level ignore list** — `boundary: [ignore: [...]]` in
     `mix.exs` is not a real option. Classify per module instead:
     - Pure leaf utility, freely depended upon (cf. `Slackex.Vault`, `Slackex.Repo`):
       `use Boundary, deps: [], check: [in: false]`
     - Bootstrap/operator module that wires into everything (cf. `Slackex.Release`):
       `use Boundary, check: [in: false, out: false]` with a justifying comment
     - Mix task: `use Boundary, classify_to: Slackex.MixTasks`
   - Verify with `mix boundary.spec` (the new context must appear) and a clean
     `mix compile --warnings-as-errors`. The compiler warns on unclassified modules
     and on forbidden cross-boundary references, so CI catches a missing
     `use Boundary` — but only because `:boundary` precedes `Mix.compilers()` in
     `mix.exs` (tracer order; pinned by `Slackex.BoundaryContractTest`). History:
     `Sous`, `Factory`, `Analytics`, and `Markdown` went unbounded for months
     because the compiler order was wrong and enforcement was silently inert
     (slackex-n3c).

3. **Guard the context module** — find the public function(s) that implement
   the new behaviour and wrap the new path:
   ```elixir
   def some_action(user, params) do
     if FunWithFlags.enabled?(:your_flag, for: user) do
       # new behaviour
     else
       {:error, :not_available}
     end
   end
   ```
   The flag check belongs in `lib/slackex/<context>/<context>.ex` — the public
   API boundary — not deep in an internal module.

4. **Guard the LiveView template** — find the component or section in the
   relevant `.html.heex` template that surfaces the feature and wrap it:
   ```heex
   <%= if FunWithFlags.enabled?(:your_flag, for: @current_user) do %>
     <.your_feature_component />
   <% end %>
   ```
   Do not rely on UI hiding alone — the context guard must also be present.

5. **Verify guards and boundary exist** — confirm before finishing:
   - [ ] New context (if any) declares `use Boundary` (or per-module `check:`/`classify_to:` with a comment) and appears in `mix boundary.spec`
   - [ ] Context module rejects the action when flag is off (`{:error, :not_available}`)
   - [ ] LiveView template hides the UI when flag is off
   - [ ] Flag atom is snake_case and descriptive
   - [ ] No nested flags or flag dependencies introduced

6. **Create an evolution doc stub** at `docs/evolution/<YYYY-MM-DD>-<feature-name>.md`
   with at minimum:
   ```markdown
   # <Feature Name>

   **Date:** <today>
   **Flag:** `:<flag_atom>`
   **Status:** In development

   ## Summary
   <one sentence describing the feature>

   ## Lifecycle
   - [ ] Develop (flag off)
   - [ ] Deploy behind flag
   - [ ] PO validation
   - [ ] Global enable
   - [ ] Contract (remove flag)
   ```

7. **Remind the user** of the lifecycle:
   - Flag defaults to off — feature is invisible after deploy
   - Enable for test users via `/admin/flags` (dev: `admin`/`devpassword`)
   - After PO approval: enable globally, then remove the flag in a follow-up PR

## Important

- FunWithFlags uses an ETS cache (15-min TTL) — flag checks are cheap, use them freely.
- FunWithFlags auto-starts as an OTP application — never add `FunWithFlags.Supervisor` to `application.ex`.
- Flags that have been globally enabled for more than one release cycle must be removed (contract phase).
- Every context must be bounded. The compiler now warns on unclassified modules (and CI fails on warnings), but that safety net depends on `:boundary` staying first in the `mix.exs` compilers list — it was silently inert for months when ordered wrong (slackex-n3c). Treat Step 2 as mandatory, not optional.
