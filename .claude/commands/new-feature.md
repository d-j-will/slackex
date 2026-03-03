Scaffold a new user-facing feature behind a FunWithFlags feature flag.

All new user-facing features must be invisible until PO-approved. This skill
ensures the flag is added in both the required locations and that nothing ships
exposed.

## Steps

1. **Confirm the feature name** if not already provided. Derive the flag atom:
   - Use snake_case: `:message_reactions`, `:threaded_replies`, `:invite_links`
   - One flag per feature — do not reuse an existing flag for new behaviour

2. **Guard the context module** — find the public function(s) that implement
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

3. **Guard the LiveView template** — find the component or section in the
   relevant `.html.heex` template that surfaces the feature and wrap it:
   ```heex
   <%= if FunWithFlags.enabled?(:your_flag, for: @current_user) do %>
     <.your_feature_component />
   <% end %>
   ```
   Do not rely on UI hiding alone — the context guard must also be present.

4. **Verify both guards exist** — confirm before finishing:
   - [ ] Context module rejects the action when flag is off (`{:error, :not_available}`)
   - [ ] LiveView template hides the UI when flag is off
   - [ ] Flag atom is snake_case and descriptive
   - [ ] No nested flags or flag dependencies introduced

5. **Create an evolution doc stub** at `docs/evolution/<YYYY-MM-DD>-<feature-name>.md`
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

6. **Remind the user** of the lifecycle:
   - Flag defaults to off — feature is invisible after deploy
   - Enable for test users via `/admin/flags` (dev: `admin`/`devpassword`)
   - After PO approval: enable globally, then remove the flag in a follow-up PR

## Important

- FunWithFlags uses an ETS cache (15-min TTL) — flag checks are cheap, use them freely.
- FunWithFlags auto-starts as an OTP application — never add `FunWithFlags.Supervisor` to `application.ex`.
- Flags that have been globally enabled for more than one release cycle must be removed (contract phase).
