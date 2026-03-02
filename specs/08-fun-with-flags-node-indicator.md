# Plan: Install FunWithFlags + Cluster Node Indicator

## Context

We just deployed a 2-node Elixir cluster (app1/app2 via Docker Compose with Horde + Gossip). We need a way to visually confirm which node is serving a user's LiveView session. This is also the right time to install FunWithFlags — the project's documented feature flag convention — since the node indicator should be gated behind a flag.

## Part 1: Install FunWithFlags Infrastructure

### Step 1 — Add dependencies
**`mix.exs`** (deps list, ~line 64)
- `{:fun_with_flags, "~> 1.13"}`
- `{:fun_with_flags_ui, "~> 1.1"}`

### Step 2 — Create migration
**New file: `priv/repo/migrations/<timestamp>_create_fun_with_flags_toggles.exs`**
- Create `fun_with_flags_toggles` table: `id` (bigserial PK), `flag_name`, `gate_type`, `target`, `enabled`
- Unique index on `[flag_name, gate_type, target]`
- Pure expand migration — deploy-safe

### Step 3 — Configure FunWithFlags
**`config/config.exs`** — add after Oban config:
- Persistence: `FunWithFlags.Store.Persistent.Ecto` with `Slackex.Repo`
- Cache: ETS enabled, 15-min TTL
- Notifications: `FunWithFlags.Notifications.PhoenixPubSub` with `Slackex.PubSub` (cross-node cache busting without a separate Redis connection)

**`config/test.exs`** — disable cache + notifications (prevents flag state leaking between tests)

### Step 4 — Add to supervision tree
**`lib/slackex/application.ex`** — insert `FunWithFlags.Supervisor` after Oban, before Endpoint

### Step 5 — Implement Actor protocol
**New file: `lib/slackex/accounts/user_flags_actor.ex`**
- `defimpl FunWithFlags.Actor, for: Slackex.Accounts.User`
- `def id(%{id: id}), do: "user:#{id}"`

### Step 6 — Mount admin UI
**`lib/slackex_web/router.ex`** — new scope with basic auth:
- `scope "/admin/flags"` forwarding to `FunWithFlags.UI.Router`
- Basic auth credentials via config (env vars in prod, hardcoded in dev/test)

**`config/dev.exs`** — add `flags_admin_auth` config (admin/devpassword)
**`config/test.exs`** — add `flags_admin_auth` config (admin/testpassword)
**`config/runtime.exs`** — add `flags_admin_auth` from env vars (prod)

## Part 2: Cluster Node Indicator Feature

### Step 7 — Flag check in mount
**`lib/slackex_web/live/chat_live/index.ex`** — in `mount/3` (~line 78):
- Add `|> assign(:show_node, FunWithFlags.enabled?(:show_cluster_node, for: user))`
- Add `|> assign(:node_name, short_node_name())`
- Add private `defp short_node_name/0` — extracts "app1" from `:"slackex@app1"`

### Step 8 — Pass assigns to sidebar
**`lib/slackex_web/live/chat_live/index.ex`** — live_component call (~line 1063):
- Add `show_node={@show_node}` and `node_name={@node_name}`

### Step 9 — Render badge in sidebar footer
**`lib/slackex_web/live/chat_live/sidebar_component.ex`** — footer (~line 260):
- Between username span and edit-profile button:
```heex
<%= if @show_node do %>
  <span class="badge badge-info badge-sm font-mono shrink-0">{@node_name}</span>
<% end %>
```

## Part 3: Tests

### Step 10 — Tests
- **Actor protocol test** (new file): verify `FunWithFlags.Actor.id/1` returns `"user:<id>"`
- **Node indicator test** (in existing ChatLive test): flag off = no badge, flag on = badge visible

## Files Modified
| File | Change |
|---|---|
| `mix.exs` | Add 2 deps |
| `config/config.exs` | FunWithFlags config |
| `config/dev.exs` | Admin auth creds |
| `config/test.exs` | Disable cache/notifications, admin auth |
| `config/runtime.exs` | Admin auth from env vars |
| `lib/slackex/application.ex` | Add FunWithFlags.Supervisor |
| `lib/slackex_web/router.ex` | Admin flags scope |
| `lib/slackex/accounts/user_flags_actor.ex` | New — Actor protocol |
| `lib/slackex_web/live/chat_live/index.ex` | Mount assigns + helper |
| `lib/slackex_web/live/chat_live/sidebar_component.ex` | Badge render |
| `priv/repo/migrations/..._create_fun_with_flags_toggles.exs` | New — flags table |
| `test/slackex/accounts/user_flags_actor_test.exs` | New — Actor test |

## Verification
1. `mix deps.get && mix ecto.migrate`
2. `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test`
3. Start dev server, visit `/admin/flags` — should see FunWithFlags UI
4. Create `:show_cluster_node` flag, enable for your user
5. Visit `/chat` — blue badge with node name should appear in sidebar footer
6. Disable the flag — badge disappears on next mount
