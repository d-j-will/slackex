# PWA Push Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Web Push notifications in Tenun's PWA so users receive push notifications for new messages, DMs, and mentions when offline — with per-channel preference controls.

**Architecture:** Plugs into the existing notification backend (PushWorker, OnlineTracker, DeviceTokenController). Adds a `WebPushAdapter` using `web_push_elixir` (VAPID), a `notification_preferences` table for per-channel settings, and client-side subscription management via a JS hook. Service worker handles push display with smart tag-based grouping.

**Tech Stack:** `web_push_elixir` (VAPID Web Push), Oban (existing `:notifications` queue), FunWithFlags (feature gating), Phoenix LiveView (settings UI)

**Spec:** `docs/superpowers/specs/2026-04-02-pwa-push-notifications-design.md`

---

## File Structure

### New Files

```
lib/slackex/notifications/web_push_adapter.ex        — Web Push adapter (replaces Stub in prod)
lib/slackex/notifications/preference.ex               — Notification preference schema + context
lib/slackex/notifications/mention.ex                  — Mention detection with word-boundary regex
lib/slackex/notifications/subscription_cleanup_worker.ex — Monthly Oban cron for stale token cleanup
lib/mix/tasks/tenun.gen.vapid_keys.ex                 — Mix task to generate VAPID key pair
lib/mix/tasks/tenun.cleanup_web_push_tokens.ex        — Mix task for rollback cleanup
assets/js/hooks/push_subscription.js                  — Client-side permission + subscription flow
priv/repo/migrations/*_create_notification_preferences.exs — Preferences table + backfill

test/slackex/notifications/web_push_adapter_test.exs
test/slackex/notifications/preference_test.exs
test/slackex/notifications/mention_test.exs
test/slackex/notifications/push_notifications_integration_test.exs
```

### Modified Files

```
mix.exs                                               — Add web_push_elixir dep
lib/slackex/notifications/device_token.ex             — Add "web_push" to platform validation
lib/slackex/notifications/push_adapter/stub.ex        — Update to new send_push/3 signature
lib/slackex/notifications/push_worker.ex              — Add preference check + payload enhancement
lib/slackex/accounts/accounts.ex                      — Create default preference on registration
lib/slackex_web/components/layouts/root.html.heex     — Add VAPID public key meta tag
priv/static/service-worker.js                         — Add push + notificationclick handlers
assets/js/app.js                                      — Register PushSubscription hook
lib/slackex_web/live/chat_live/index.ex               — Add notification settings handlers
lib/slackex_web/components/chat_components.ex         — Add notification bell to channel header
config/runtime.exs                                    — Add WebPushAdapter config
config/config.exs                                     — Add cleanup worker cron
```

---

## Task 1: Add Dependency + VAPID Key Generation

**Files:**
- Modify: `mix.exs`
- Create: `lib/mix/tasks/tenun.gen.vapid_keys.ex`

- [ ] **Step 1: Add web_push_elixir to mix.exs**

In `mix.exs`, add to the `deps` list:

```elixir
{:web_push_elixir, "~> 0.5"}
```

- [ ] **Step 2: Install the dependency**

Run:
```bash
mix deps.get
```

- [ ] **Step 3: Write the VAPID key generation mix task**

Create `lib/mix/tasks/tenun.gen.vapid_keys.ex`:

```elixir
defmodule Mix.Tasks.Tenun.Gen.VapidKeys do
  @moduledoc "Generate a VAPID key pair for Web Push notifications."
  @shortdoc "Generate VAPID keys"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

    public_b64 = Base.url_encode64(public, padding: false)
    private_b64 = Base.url_encode64(private, padding: false)

    Mix.shell().info("""
    VAPID keys generated successfully.

    Add these to your .env file:

      VAPID_PUBLIC_KEY=#{public_b64}
      VAPID_PRIVATE_KEY=#{private_b64}

    The public key is safe to expose to browsers.
    The private key must be kept secret.
    """)
  end
end
```

- [ ] **Step 4: Verify the task runs**

Run:
```bash
mix tenun.gen.vapid_keys
```
Expected: Outputs a public/private key pair.

**Important:** Before committing, verify the key generation approach matches what `web_push_elixir` expects. Check the library docs — it may have its own key generation helper. If so, use that instead of raw `:crypto`.

- [ ] **Step 5: Add VAPID config to runtime.exs**

In `config/runtime.exs`, add within the production config block:

```elixir
config :slackex, Slackex.Notifications.WebPushAdapter,
  vapid_public_key: System.get_env("VAPID_PUBLIC_KEY"),
  vapid_private_key: System.get_env("VAPID_PRIVATE_KEY"),
  vapid_subject: "mailto:admin@tenun.dev"
```

- [ ] **Step 6: Add VAPID public key meta tag to root layout**

In `lib/slackex_web/components/layouts/root.html.heex`, add inside `<head>`:

```heex
<meta name="vapid-public-key" content={Application.get_env(:slackex, Slackex.Notifications.WebPushAdapter, [])[:vapid_public_key] || ""} />
```

- [ ] **Step 7: Commit**

```bash
git add mix.exs mix.lock lib/mix/tasks/tenun.gen.vapid_keys.ex config/runtime.exs lib/slackex_web/components/layouts/root.html.heex
git commit -m "feat(push): add web_push_elixir dep, VAPID key generation, and config"
```

---

## Task 2: Update DeviceToken + Refactor Adapter Interface

**Files:**
- Modify: `lib/slackex/notifications/device_token.ex`
- Modify: `lib/slackex/notifications/push_adapter/stub.ex`
- Modify: `lib/slackex/notifications/push_worker.ex`
- Test: `test/slackex/notifications/web_push_adapter_test.exs` (stub adapter test only for now)

- [ ] **Step 1: Write test for DeviceToken accepting "web_push" platform**

Add to existing DeviceToken tests or create a new test:

```elixir
test "accepts web_push as a valid platform" do
  user = insert(:user)
  subscription_json = Jason.encode!(%{endpoint: "https://push.example.com", keys: %{p256dh: "key1", auth: "key2"}})

  changeset = DeviceToken.changeset(%DeviceToken{}, %{
    user_id: user.id,
    token: subscription_json,
    platform: "web_push",
    device_name: "Chrome PWA"
  })

  assert changeset.valid?
end
```

- [ ] **Step 2: Update DeviceToken platform validation**

In `lib/slackex/notifications/device_token.ex`, change line 25:

```elixir
# Before:
|> validate_inclusion(:platform, ["fcm", "apns"])

# After:
|> validate_inclusion(:platform, ["fcm", "apns", "web_push"])
```

Also update the platform length validation to accommodate "web_push" (9 chars, existing max is 10 — this is fine).

- [ ] **Step 3: Run test to verify it passes**

Run:
```bash
mix test test/slackex/notifications/ --trace
```

- [ ] **Step 4: Refactor StubAdapter to new signature**

In `lib/slackex/notifications/push_adapter/stub.ex`, change:

```elixir
# Before:
@spec send_push(String.t(), String.t(), String.t(), String.t()) :: :ok
def send_push(token, platform, title, body) do
  Logger.debug("[PushAdapter.Stub] #{platform} → #{token}: #{title} — #{body}")
  :ok
end

# After:
@spec send_push(String.t(), String.t(), map()) :: :ok | {:error, term()}
def send_push(token, platform, payload) do
  Logger.debug("[PushAdapter.Stub] #{platform} → #{String.slice(token, 0, 40)}...: #{payload["title"]} — #{payload["body"]}")
  :ok
end
```

- [ ] **Step 5: Update PushWorker to use new adapter signature**

In `lib/slackex/notifications/push_worker.ex`, find where the adapter is called (around line 113-114):

```elixir
# Before:
adapter.send_push(token, platform, title, body)

# After:
payload = %{
  "title" => title,
  "body" => body,
  "tag" => build_tag(args),
  "url" => build_url(args),
  "type" => args["type"]
}
adapter.send_push(token, platform, payload)
```

Add these private helpers in PushWorker:

```elixir
defp build_tag(%{"type" => "new_message", "channel_id" => channel_id}) do
  "channel:#{channel_id}"
end

defp build_tag(%{"type" => "new_dm", "dm_conversation_id" => dm_id} = args) do
  "dm:#{dm_id}:#{args["message_id"] || "latest"}"
end

defp build_tag(_args), do: "general"

defp build_url(%{"type" => "new_message", "channel_slug" => slug}) when is_binary(slug) do
  "/chat/#{slug}"
end

defp build_url(%{"type" => "new_dm", "dm_conversation_id" => dm_id}) do
  "/chat/dm/#{dm_id}"
end

defp build_url(_args), do: "/chat"
```

Note: `channel_slug` may not be in the current args. Check the existing args structure and add `channel_slug` to the enqueue call in ChannelServer if needed, or look it up from the channel_id.

- [ ] **Step 6: Run full test suite to verify no regressions**

Run:
```bash
mix test --max-failures 5
```

- [ ] **Step 7: Commit**

```bash
git add lib/slackex/notifications/device_token.ex lib/slackex/notifications/push_adapter/stub.ex lib/slackex/notifications/push_worker.ex
git commit -m "feat(push): update DeviceToken for web_push, refactor adapter to payload map"
```

---

## Task 3: Notification Preferences Schema + Context

**Files:**
- Create: `priv/repo/migrations/*_create_notification_preferences.exs`
- Create: `lib/slackex/notifications/preference.ex`
- Modify: `lib/slackex/accounts/accounts.ex`
- Test: `test/slackex/notifications/preference_test.exs`

- [ ] **Step 1: Generate the migration**

Run:
```bash
mix ecto.gen.migration create_notification_preferences
```

- [ ] **Step 2: Write the migration**

```elixir
defmodule Slackex.Repo.Migrations.CreateNotificationPreferences do
  use Ecto.Migration

  def change do
    create table(:notification_preferences) do
      add :user_id, references(:users, type: :bigint, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, type: :bigint, on_delete: :delete_all), null: true
      add :level, :string, null: false, default: "all"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_preferences, [:user_id, :channel_id],
      name: :notification_preferences_user_channel_idx,
      nulls_distinct: false
    )

    create index(:notification_preferences, [:user_id])

    # Backfill global defaults for existing users
    execute(
      "INSERT INTO notification_preferences (user_id, channel_id, level, inserted_at, updated_at) SELECT id, NULL, 'all', NOW(), NOW() FROM users",
      "DELETE FROM notification_preferences WHERE channel_id IS NULL"
    )
  end
end
```

Note: `nulls_distinct: false` is needed for PostgreSQL 15+ to treat `(user_id, NULL)` as a duplicate of another `(user_id, NULL)`. Check your PostgreSQL version — if below 15, use a partial unique index instead:

```elixir
create unique_index(:notification_preferences, [:user_id],
  where: "channel_id IS NULL",
  name: :notification_preferences_user_global_idx
)
create unique_index(:notification_preferences, [:user_id, :channel_id],
  where: "channel_id IS NOT NULL",
  name: :notification_preferences_user_channel_idx
)
```

- [ ] **Step 3: Run migration**

Run:
```bash
mix ecto.migrate
```

- [ ] **Step 4: Write the Preference schema and context tests**

Create `test/slackex/notifications/preference_test.exs`:

```elixir
defmodule Slackex.Notifications.PreferenceTest do
  use Slackex.DataCase, async: true

  alias Slackex.Notifications.Preference

  describe "resolve_level/2" do
    test "returns per-channel level when set" do
      user = insert(:user)
      channel = insert(:channel)

      Preference.set_preference(user.id, channel.id, "nothing")

      assert Preference.resolve_level(user.id, channel.id) == "nothing"
    end

    test "falls back to global default when no per-channel preference" do
      user = insert(:user)
      channel = insert(:channel)

      # Global default already exists from migration backfill
      Preference.set_global_default(user.id, "mentions")

      assert Preference.resolve_level(user.id, channel.id) == "mentions"
    end

    test "returns 'all' from backfilled global default" do
      user = insert(:user)
      channel = insert(:channel)

      # The migration backfill created a global default of "all"
      assert Preference.resolve_level(user.id, channel.id) == "all"
    end
  end

  describe "set_preference/3" do
    test "creates a per-channel preference" do
      user = insert(:user)
      channel = insert(:channel)

      assert {:ok, pref} = Preference.set_preference(user.id, channel.id, "mentions")
      assert pref.level == "mentions"
      assert pref.channel_id == channel.id
    end

    test "updates existing preference" do
      user = insert(:user)
      channel = insert(:channel)

      {:ok, _} = Preference.set_preference(user.id, channel.id, "mentions")
      {:ok, pref} = Preference.set_preference(user.id, channel.id, "nothing")

      assert pref.level == "nothing"
    end
  end

  describe "set_global_default/2" do
    test "updates the global default level" do
      user = insert(:user)

      {:ok, pref} = Preference.set_global_default(user.id, "mentions")
      assert pref.level == "mentions"
      assert is_nil(pref.channel_id)
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they fail**

Run:
```bash
mix test test/slackex/notifications/preference_test.exs --trace
```
Expected: FAIL — module `Preference` not found.

- [ ] **Step 6: Write the Preference schema and context module**

Create `lib/slackex/notifications/preference.ex`:

```elixir
defmodule Slackex.Notifications.Preference do
  @moduledoc "Notification preference per user per channel. NULL channel_id = global default."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Slackex.Repo

  @valid_levels ~w(all mentions nothing)

  schema "notification_preferences" do
    field :level, :string, default: "all"
    belongs_to :user, Slackex.Accounts.User
    belongs_to :channel, Slackex.Chat.Channel
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:user_id, :channel_id, :level])
    |> validate_required([:user_id, :level])
    |> validate_inclusion(:level, @valid_levels)
    |> unique_constraint([:user_id, :channel_id], name: :notification_preferences_user_channel_idx)
  end

  @doc "Resolve the effective notification level for a user in a channel."
  def resolve_level(user_id, channel_id) do
    case get_by_channel(user_id, channel_id) do
      %{level: level} -> level
      nil -> get_global_default_level(user_id)
    end
  end

  @doc "Set a per-channel notification preference."
  def set_preference(user_id, channel_id, level) do
    case Repo.get_by(__MODULE__, user_id: user_id, channel_id: channel_id) do
      nil -> %__MODULE__{user_id: user_id, channel_id: channel_id}
      existing -> existing
    end
    |> changeset(%{level: level})
    |> Repo.insert_or_update()
  end

  @doc "Set or update the global default notification level."
  def set_global_default(user_id, level) do
    case Repo.get_by(__MODULE__, user_id: user_id, channel_id: nil) do
      nil -> %__MODULE__{user_id: user_id, channel_id: nil}
      existing -> existing
    end
    |> changeset(%{level: level})
    |> Repo.insert_or_update()
  end

  @doc "Create the default global preference for a new user."
  def create_default_for_user(user_id) do
    %__MODULE__{}
    |> changeset(%{user_id: user_id, channel_id: nil, level: "all"})
    |> Repo.insert(on_conflict: :nothing, conflict_target: {:unsafe_fragment, "(user_id) WHERE channel_id IS NULL"})
  end

  defp get_by_channel(user_id, channel_id) do
    __MODULE__
    |> where([p], p.user_id == ^user_id and p.channel_id == ^channel_id)
    |> Repo.one()
  end

  defp get_global_default_level(user_id) do
    __MODULE__
    |> where([p], p.user_id == ^user_id and is_nil(p.channel_id))
    |> select([p], p.level)
    |> Repo.one() || "all"
  end
end
```

- [ ] **Step 7: Hook into user registration**

In `lib/slackex/accounts/accounts.ex`, modify `register_user/1`:

```elixir
def register_user(attrs) do
  result =
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()

  case result do
    {:ok, user} ->
      Slackex.Notifications.Preference.create_default_for_user(user.id)
      {:ok, user}

    error ->
      error
  end
end
```

- [ ] **Step 8: Run tests to verify they pass**

Run:
```bash
mix test test/slackex/notifications/preference_test.exs --trace
```
Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add priv/repo/migrations/*_create_notification_preferences.exs lib/slackex/notifications/preference.ex lib/slackex/accounts/accounts.ex test/slackex/notifications/preference_test.exs
git commit -m "feat(push): add notification preferences schema with per-channel levels"
```

---

## Task 4: Mention Detection Module

**Files:**
- Create: `lib/slackex/notifications/mention.ex`
- Test: `test/slackex/notifications/mention_test.exs`

- [ ] **Step 1: Write mention detection tests**

Create `test/slackex/notifications/mention_test.exs`:

```elixir
defmodule Slackex.Notifications.MentionTest do
  use ExUnit.Case, async: true

  alias Slackex.Notifications.Mention

  describe "mentioned?/2" do
    test "detects @username mention" do
      assert Mention.mentioned?("hey @alice check this", "alice")
    end

    test "is case-insensitive" do
      assert Mention.mentioned?("hey @Alice check this", "alice")
    end

    test "does not match partial words" do
      refute Mention.mentioned?("paying with cash", "ash")
      refute Mention.mentioned?("the dashboard is broken", "ash")
    end

    test "matches at start of string" do
      assert Mention.mentioned?("@bob hello", "bob")
    end

    test "matches at end of string" do
      assert Mention.mentioned?("hello @bob", "bob")
    end

    test "does not match without @ prefix" do
      refute Mention.mentioned?("hey bob check this", "bob")
    end

    test "handles special regex characters in username" do
      assert Mention.mentioned?("hey @user.name check", "user.name")
    end

    test "does not match email-like patterns" do
      refute Mention.mentioned?("email me at bob@example.com", "bob")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
mix test test/slackex/notifications/mention_test.exs --trace
```
Expected: FAIL — module not found.

- [ ] **Step 3: Write the Mention module**

Create `lib/slackex/notifications/mention.ex`:

```elixir
defmodule Slackex.Notifications.Mention do
  @moduledoc "Detects @username mentions in message content using word-boundary regex."

  @doc """
  Returns true if `content` contains an @mention of `username`.
  Uses word-boundary matching to prevent false positives.
  Case-insensitive. Runs against raw plaintext.
  """
  @spec mentioned?(String.t(), String.t()) :: boolean()
  def mentioned?(content, username) when is_binary(content) and is_binary(username) do
    escaped = Regex.escape(username)
    pattern = Regex.compile!("(?<!\\w)@#{escaped}\\b", "i")
    Regex.match?(pattern, content)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
mix test test/slackex/notifications/mention_test.exs --trace
```
Expected: All 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/notifications/mention.ex test/slackex/notifications/mention_test.exs
git commit -m "feat(push): add Mention module with word-boundary regex detection"
```

---

## Task 5: WebPushAdapter

**Files:**
- Create: `lib/slackex/notifications/web_push_adapter.ex`
- Test: `test/slackex/notifications/web_push_adapter_test.exs`

- [ ] **Step 1: Write WebPushAdapter tests**

Create `test/slackex/notifications/web_push_adapter_test.exs`:

```elixir
defmodule Slackex.Notifications.WebPushAdapterTest do
  use Slackex.DataCase, async: true

  alias Slackex.Notifications.WebPushAdapter

  describe "build_payload/1" do
    test "builds correct JSON payload from map" do
      payload = %{
        "title" => "#general",
        "body" => "alice: hello world",
        "tag" => "channel:123",
        "url" => "/chat/general",
        "type" => "new_message"
      }

      json = WebPushAdapter.build_payload(payload)
      decoded = Jason.decode!(json)

      assert decoded["title"] == "#general"
      assert decoded["body"] == "alice: hello world"
      assert decoded["tag"] == "channel:123"
      assert decoded["url"] == "/chat/general"
      assert decoded["type"] == "new_message"
    end
  end

  describe "decode_subscription/1" do
    test "parses valid subscription JSON" do
      subscription = %{
        "endpoint" => "https://push.example.com/sub/123",
        "keys" => %{"p256dh" => "publickey", "auth" => "authsecret"}
      }

      token = Jason.encode!(subscription)
      assert {:ok, decoded} = WebPushAdapter.decode_subscription(token)
      assert decoded["endpoint"] == "https://push.example.com/sub/123"
      assert decoded["keys"]["p256dh"] == "publickey"
    end

    test "returns error for invalid JSON" do
      assert {:error, :invalid_subscription} = WebPushAdapter.decode_subscription("not json")
    end

    test "returns error for missing endpoint" do
      token = Jason.encode!(%{"keys" => %{}})
      assert {:error, :invalid_subscription} = WebPushAdapter.decode_subscription(token)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
mix test test/slackex/notifications/web_push_adapter_test.exs --trace
```

- [ ] **Step 3: Write the WebPushAdapter**

Create `lib/slackex/notifications/web_push_adapter.ex`:

```elixir
defmodule Slackex.Notifications.WebPushAdapter do
  @moduledoc """
  Web Push adapter using web_push_elixir and VAPID keys.
  Implements the push adapter interface: send_push/3.
  """

  require Logger

  alias Slackex.Notifications.DeviceToken
  alias Slackex.Repo

  @spec send_push(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def send_push(token, _platform, payload) do
    with {:ok, subscription} <- decode_subscription(token),
         {:ok, vapid_config} <- get_vapid_config() do
      json_payload = build_payload(payload)

      case WebPushElixir.send_notification(
             subscription["endpoint"],
             json_payload,
             subscription["keys"]["auth"],
             subscription["keys"]["p256dh"],
             vapid_config
           ) do
        {:ok, _response} ->
          :ok

        {:error, %{status: 410}} ->
          Logger.info("[WebPush] Subscription expired (410), cleaning up token")
          cleanup_expired_token(token)
          :ok

        {:error, %{status: 404}} ->
          Logger.info("[WebPush] Subscription not found (404), cleaning up token")
          cleanup_expired_token(token)
          :ok

        {:error, reason} ->
          Logger.warning("[WebPush] Push failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc "Build the JSON payload string from a map."
  def build_payload(payload) do
    Jason.encode!(%{
      "title" => payload["title"],
      "body" => payload["body"],
      "tag" => payload["tag"],
      "url" => payload["url"],
      "type" => payload["type"]
    })
  end

  @doc "Decode and validate a Web Push subscription JSON string."
  def decode_subscription(token) do
    case Jason.decode(token) do
      {:ok, %{"endpoint" => endpoint, "keys" => %{"p256dh" => _, "auth" => _}} = sub}
          when is_binary(endpoint) ->
        {:ok, sub}

      {:ok, _invalid} ->
        {:error, :invalid_subscription}

      {:error, _} ->
        {:error, :invalid_subscription}
    end
  end

  defp get_vapid_config do
    config = Application.get_env(:slackex, __MODULE__, [])
    public_key = config[:vapid_public_key]
    private_key = config[:vapid_private_key]
    subject = config[:vapid_subject]

    if public_key && private_key && subject do
      {:ok, %{
        public_key: public_key,
        private_key: private_key,
        subject: subject
      }}
    else
      Logger.warning("[WebPush] VAPID keys not configured")
      {:error, :vapid_not_configured}
    end
  end

  defp cleanup_expired_token(token) do
    case Repo.get_by(DeviceToken, token: token) do
      nil -> :ok
      device_token -> Repo.delete(device_token)
    end
  end
end
```

**Important:** The exact `WebPushElixir.send_notification/5` API must be verified against the library docs during implementation. The function signature, argument order, and response format may differ. Check `mix hex.info web_push_elixir` and the library source.

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
mix test test/slackex/notifications/web_push_adapter_test.exs --trace
```

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/notifications/web_push_adapter.ex test/slackex/notifications/web_push_adapter_test.exs
git commit -m "feat(push): add WebPushAdapter with VAPID support and subscription validation"
```

---

## Task 6: PushWorker Preference Check

**Files:**
- Modify: `lib/slackex/notifications/push_worker.ex`

- [ ] **Step 1: Add preference checking to PushWorker**

In the `perform/1` function for `"new_message"` type, before the adapter call, add:

```elixir
# After fetching the list of offline subscribers to notify, filter by preferences:
alias Slackex.Notifications.Preference
alias Slackex.Notifications.Mention

# For each subscriber being notified:
level = Preference.resolve_level(subscriber_user_id, channel_id)

case level do
  "nothing" ->
    :skip

  "mentions" ->
    if Mention.mentioned?(content, subscriber_username) do
      # Send notification with type "mention" instead of "channel"
      send_notification(token, platform, %{payload | "type" => "new_mention"})
    else
      :skip
    end

  "all" ->
    send_notification(token, platform, payload)
end
```

The exact integration point depends on the PushWorker's structure. Read the existing `perform/1` for `"new_message"` and find where it iterates over device tokens to send. Insert the preference check there.

- [ ] **Step 2: Add feature flag check**

At the top of each `perform/1` clause, add:

```elixir
if FunWithFlags.enabled?(:push_notifications) do
  # existing logic
else
  :ok
end
```

- [ ] **Step 3: Run full test suite**

Run:
```bash
mix test --max-failures 5
```

- [ ] **Step 4: Commit**

```bash
git add lib/slackex/notifications/push_worker.ex
git commit -m "feat(push): add preference checking and feature flag to PushWorker"
```

---

## Task 7: Service Worker Push Handlers

**Files:**
- Modify: `priv/static/service-worker.js`

- [ ] **Step 1: Add push event listener**

In `priv/static/service-worker.js`, add after the existing event listeners:

```javascript
// Push notification handler
self.addEventListener('push', (event) => {
  const data = event.data?.json() || {};
  const options = {
    body: data.body || '',
    tag: data.tag || 'tenun-default',
    renotify: true,
    icon: '/images/icon-192.png',
    badge: '/images/icon-192.png',
    data: { url: data.url || '/chat' },
  };

  event.waitUntil(
    self.registration.showNotification(data.title || 'Tenun', options)
      .catch(err => console.error('[SW] showNotification failed:', err))
  );
});

// Notification click handler — open or focus the app
self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windowClients) => {
      // Focus existing window if open
      for (const client of windowClients) {
        if (client.url.includes('/chat') && 'focus' in client) {
          client.navigate(event.notification.data.url);
          return client.focus();
        }
      }
      // Otherwise open new window
      return clients.openWindow(event.notification.data.url);
    })
  );
});
```

- [ ] **Step 2: Commit**

```bash
git add priv/static/service-worker.js
git commit -m "feat(push): add service worker push and notificationclick handlers"
```

---

## Task 8: Client-Side Subscription Hook

**Files:**
- Create: `assets/js/hooks/push_subscription.js`
- Modify: `assets/js/app.js`

- [ ] **Step 1: Write the PushSubscription hook**

Create `assets/js/hooks/push_subscription.js`:

```javascript
const PushSubscription = {
  mounted() {
    this.handleEvent("push:check_status", () => {
      this._checkSubscriptionStatus();
    });

    this.handleEvent("push:subscribe", () => {
      this._subscribe();
    });

    this.handleEvent("push:unsubscribe", () => {
      this._unsubscribe();
    });
  },

  async _checkSubscriptionStatus() {
    const permission = Notification.permission;
    const registration = await navigator.serviceWorker?.ready;
    const subscription = await registration?.pushManager?.getSubscription();

    this.pushEvent("push:status", {
      permission: permission,
      subscribed: !!subscription,
    });
  },

  async _subscribe() {
    try {
      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        this.pushEvent("push:error", { reason: "permission_denied" });
        return;
      }

      const registration = await navigator.serviceWorker.ready;
      const vapidKey = document.querySelector('meta[name="vapid-public-key"]')?.content;

      if (!vapidKey) {
        this.pushEvent("push:error", { reason: "no_vapid_key" });
        return;
      }

      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: this._urlBase64ToUint8Array(vapidKey),
      });

      // Send subscription to server
      const token = document.querySelector('meta[name="csrf-token"]')?.content;
      const response = await fetch("/api/device-tokens", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": token,
          "Authorization": `Bearer ${this._getAuthToken()}`,
        },
        body: JSON.stringify({
          token: JSON.stringify(subscription),
          platform: "web_push",
          device_name: navigator.userAgent.slice(0, 100),
        }),
      });

      if (response.ok) {
        this.pushEvent("push:subscribed", {});
      } else {
        this.pushEvent("push:error", { reason: "registration_failed" });
      }
    } catch (err) {
      console.error("[Push] Subscribe failed:", err);
      this.pushEvent("push:error", { reason: err.message });
    }
  },

  async _unsubscribe() {
    try {
      const registration = await navigator.serviceWorker.ready;
      const subscription = await registration.pushManager.getSubscription();

      if (subscription) {
        const token = JSON.stringify(subscription);

        // Unsubscribe from browser
        await subscription.unsubscribe();

        // Remove from server
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
        await fetch("/api/device-tokens", {
          method: "DELETE",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": csrfToken,
            "Authorization": `Bearer ${this._getAuthToken()}`,
          },
          body: JSON.stringify({ token: token }),
        });
      }

      this.pushEvent("push:unsubscribed", {});
    } catch (err) {
      console.error("[Push] Unsubscribe failed:", err);
      this.pushEvent("push:error", { reason: err.message });
    }
  },

  _getAuthToken() {
    // Guardian JWT token — check how the app stores it (localStorage, cookie, etc.)
    // This depends on the existing auth pattern. Check DeviceTokenController auth.
    return localStorage.getItem("guardian_token") || "";
  },

  _urlBase64ToUint8Array(base64String) {
    const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
    const rawData = window.atob(base64);
    return Uint8Array.from([...rawData].map((char) => char.charCodeAt(0)));
  },
};

export default PushSubscription;
```

**Important:** The auth mechanism for the `/api/device-tokens` endpoint uses Guardian. Check how the existing app sends the Bearer token — it may be in a cookie or localStorage. The `_getAuthToken()` helper needs to match the existing pattern.

- [ ] **Step 2: Register the hook in app.js**

In `assets/js/app.js`, add import:

```javascript
import PushSubscription from "./hooks/push_subscription"
```

Add to the hooks object:

```javascript
hooks: {...existing..., PushSubscription},
```

- [ ] **Step 3: Commit**

```bash
git add assets/js/hooks/push_subscription.js assets/js/app.js
git commit -m "feat(push): add PushSubscription JS hook for browser permission and subscription"
```

---

## Task 9: Profile Settings — Notifications Section

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex` — add notification settings handlers
- Modify the profile edit template (find the relevant HEEx template)

- [ ] **Step 1: Add notification event handlers to index.ex**

Add these handlers:

```elixir
def handle_event("push:status", %{"permission" => permission, "subscribed" => subscribed}, socket) do
  {:noreply,
   socket
   |> assign(:push_permission, permission)
   |> assign(:push_subscribed, subscribed)}
end

def handle_event("push:subscribed", _params, socket) do
  {:noreply, assign(socket, :push_subscribed, true)}
end

def handle_event("push:unsubscribed", _params, socket) do
  {:noreply, assign(socket, :push_subscribed, false)}
end

def handle_event("push:error", %{"reason" => reason}, socket) do
  {:noreply, put_flash(socket, :error, "Push notification error: #{reason}")}
end

def handle_event("enable_push", _params, socket) do
  {:noreply, push_event(socket, "push:subscribe", %{})}
end

def handle_event("disable_push", _params, socket) do
  {:noreply, push_event(socket, "push:unsubscribe", %{})}
end

def handle_event("update_notification_level", %{"level" => level}, socket) do
  user = socket.assigns.current_user
  Slackex.Notifications.Preference.set_global_default(user.id, level)
  {:noreply, assign(socket, :notification_level, level)}
end
```

- [ ] **Step 2: Initialize notification assigns on mount**

In the mount or handle_params where the profile state is set up, add:

```elixir
notification_level =
  if FunWithFlags.enabled?(:push_notifications) do
    Slackex.Notifications.Preference.resolve_level(user.id, nil)
  else
    "all"
  end

socket
|> assign(:push_notifications_enabled, FunWithFlags.enabled?(:push_notifications))
|> assign(:push_permission, "default")
|> assign(:push_subscribed, false)
|> assign(:notification_level, notification_level)
```

- [ ] **Step 3: Add notifications section to the profile edit template**

In the profile edit form template, add after the existing fields:

```heex
<%= if @push_notifications_enabled do %>
  <div class="divider">Notifications</div>

  <div class="form-control" id="push-settings" phx-hook="PushSubscription">
    <label class="label"><span class="label-text">Push Notifications</span></label>
    <%= if @push_subscribed do %>
      <div class="flex items-center gap-2">
        <span class="badge badge-success">Enabled</span>
        <button type="button" phx-click="disable_push" class="btn btn-sm btn-ghost">Disable</button>
      </div>
    <% else %>
      <%= if @push_permission == "denied" do %>
        <p class="text-sm text-warning">Notifications blocked by browser. Reset in browser settings.</p>
      <% else %>
        <button type="button" phx-click="enable_push" class="btn btn-sm btn-primary">Enable Notifications</button>
      <% end %>
    <% end %>
  </div>

  <div class="form-control mt-4">
    <label class="label"><span class="label-text">Default Notification Level</span></label>
    <select name="level" phx-change="update_notification_level" class="select select-bordered select-sm">
      <option value="all" selected={@notification_level == "all"}>All messages</option>
      <option value="mentions" selected={@notification_level == "mentions"}>Mentions only</option>
      <option value="nothing" selected={@notification_level == "nothing"}>Nothing</option>
    </select>
  </div>
<% end %>
```

- [ ] **Step 4: Run tests to verify no regressions**

Run:
```bash
mix test --max-failures 5
```

- [ ] **Step 5: Commit**

```bash
git add lib/slackex_web/live/chat_live/index.ex
git commit -m "feat(push): add notification settings to profile with push toggle and level selector"
```

---

## Task 10: Per-Channel Notification Bell

**Files:**
- Modify: `lib/slackex_web/components/chat_components.ex` or the template that renders the channel header actions
- Modify: `lib/slackex_web/live/chat_live/index.ex` — add per-channel preference handler

- [ ] **Step 1: Add per-channel preference handler to index.ex**

```elixir
def handle_event("set_channel_notification", %{"level" => level}, socket) do
  user = socket.assigns.current_user
  channel = socket.assigns.channel

  if channel do
    Slackex.Notifications.Preference.set_preference(user.id, channel.id, level)
    {:noreply, assign(socket, :channel_notification_level, level)}
  else
    {:noreply, socket}
  end
end
```

- [ ] **Step 2: Initialize channel notification level on channel load**

When a channel is loaded (in `handle_params` for `:show` action), add:

```elixir
channel_notification_level =
  if FunWithFlags.enabled?(:push_notifications) and channel do
    Slackex.Notifications.Preference.resolve_level(user.id, channel.id)
  else
    "all"
  end

assign(socket, :channel_notification_level, channel_notification_level)
```

- [ ] **Step 3: Add notification bell to channel header actions**

In the template where the `conversation_header` component is used, add to the `:actions` slot:

```heex
<:actions>
  <%= if @push_notifications_enabled and @channel do %>
    <div class="dropdown dropdown-end">
      <label tabindex="0" class="btn btn-ghost btn-sm btn-square">
        <%= if @channel_notification_level == "nothing" do %>
          <span class="hero-bell-slash size-5 opacity-50" />
        <% else %>
          <span class="hero-bell size-5" />
        <% end %>
      </label>
      <ul tabindex="0" class="dropdown-content z-10 menu p-2 shadow bg-base-100 rounded-box w-52">
        <li>
          <button phx-click="set_channel_notification" phx-value-level="all"
            class={if @channel_notification_level == "all", do: "active"}>
            All messages
          </button>
        </li>
        <li>
          <button phx-click="set_channel_notification" phx-value-level="mentions"
            class={if @channel_notification_level == "mentions", do: "active"}>
            Mentions only
          </button>
        </li>
        <li>
          <button phx-click="set_channel_notification" phx-value-level="nothing"
            class={if @channel_notification_level == "nothing", do: "active"}>
            Mute
          </button>
        </li>
      </ul>
    </div>
  <% end %>
  <%!-- existing action buttons --%>
</:actions>
```

- [ ] **Step 4: Run tests to verify no regressions**

Run:
```bash
mix test --max-failures 5
```

- [ ] **Step 5: Commit**

```bash
git add lib/slackex_web/live/chat_live/index.ex lib/slackex_web/components/chat_components.ex
git commit -m "feat(push): add per-channel notification bell with preference dropdown"
```

---

## Task 11: Subscription Cleanup + Rollback Task

**Files:**
- Create: `lib/slackex/notifications/subscription_cleanup_worker.ex`
- Create: `lib/mix/tasks/tenun.cleanup_web_push_tokens.ex`
- Modify: `config/config.exs` — add cron entry
- Modify: `lib/slackex_web/user_auth.ex` — cleanup tokens on logout

- [ ] **Step 1: Write the SubscriptionCleanupWorker**

Create `lib/slackex/notifications/subscription_cleanup_worker.ex`:

```elixir
defmodule Slackex.Notifications.SubscriptionCleanupWorker do
  @moduledoc "Monthly Oban cron that samples web_push tokens and removes expired ones."

  use Oban.Worker, queue: :notifications, max_attempts: 1

  import Ecto.Query
  require Logger

  alias Slackex.Notifications.DeviceToken
  alias Slackex.Notifications.WebPushAdapter
  alias Slackex.Repo

  @sample_percentage 0.1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tokens =
      DeviceToken
      |> where([t], t.platform == "web_push")
      |> Repo.all()

    sample_size = max(1, round(length(tokens) * @sample_percentage))
    sampled = Enum.take_random(tokens, sample_size)

    expired_count =
      sampled
      |> Enum.count(fn token ->
        case WebPushAdapter.send_push(token.token, "web_push", %{
               "title" => "",
               "body" => "",
               "tag" => "cleanup-probe",
               "url" => "/",
               "type" => "probe"
             }) do
          :ok -> false
          {:error, _} -> true
        end
      end)

    if expired_count > 0 do
      Logger.info("SubscriptionCleanup: #{expired_count}/#{length(sampled)} sampled tokens were expired")
    end

    :ok
  end
end
```

- [ ] **Step 2: Add cron entry**

In `config/config.exs`, add to the Oban cron list:

```elixir
{"0 4 1 * *", Slackex.Notifications.SubscriptionCleanupWorker}
```

This runs at 4am on the 1st of each month.

- [ ] **Step 3: Write the rollback cleanup mix task**

Create `lib/mix/tasks/tenun.cleanup_web_push_tokens.ex`:

```elixir
defmodule Mix.Tasks.Tenun.CleanupWebPushTokens do
  @moduledoc "Delete all web_push device tokens (for rolling back push notifications)."
  @shortdoc "Delete all web_push device tokens"

  use Mix.Task

  import Ecto.Query

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    {deleted, _} =
      Slackex.Notifications.DeviceToken
      |> where([t], t.platform == "web_push")
      |> Slackex.Repo.delete_all()

    Mix.shell().info("Deleted #{deleted} web_push device tokens.")
  end
end
```

- [ ] **Step 4: Add logout cleanup**

In `lib/slackex_web/user_auth.ex`, find the `log_out_user/1` function and add before the session is cleared:

```elixir
# Clean up web push subscriptions for this user
import Ecto.Query
Slackex.Notifications.DeviceToken
|> where([t], t.user_id == ^user.id and t.platform == "web_push")
|> Slackex.Repo.delete_all()
```

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/notifications/subscription_cleanup_worker.ex lib/mix/tasks/tenun.cleanup_web_push_tokens.ex config/config.exs lib/slackex_web/user_auth.ex
git commit -m "feat(push): add subscription cleanup worker, rollback task, and logout cleanup"
```

---

## Task 12: Integration and Contract Tests

**Files:**
- Create: `test/slackex/notifications/push_notifications_integration_test.exs`

- [ ] **Step 1: Write the integration test**

Create `test/slackex/notifications/push_notifications_integration_test.exs`:

```elixir
defmodule Slackex.Notifications.PushNotificationsIntegrationTest do
  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Notifications.{Preference, DeviceToken, WebPushAdapter}
  alias Slackex.Repo

  setup do
    FunWithFlags.enable(:push_notifications)
    FunWithFlags.enable(:website_analytics)
    on_exit(fn ->
      FunWithFlags.disable(:push_notifications)
      FunWithFlags.disable(:website_analytics)
    end)
    :ok
  end

  describe "preference resolution" do
    test "per-channel overrides global default" do
      user = insert(:user)
      channel = insert(:channel)

      Preference.set_global_default(user.id, "all")
      Preference.set_preference(user.id, channel.id, "nothing")

      assert Preference.resolve_level(user.id, channel.id) == "nothing"
    end

    test "falls back to global when no per-channel preference" do
      user = insert(:user)
      channel = insert(:channel)

      Preference.set_global_default(user.id, "mentions")

      assert Preference.resolve_level(user.id, channel.id) == "mentions"
    end
  end

  describe "WebPushAdapter payload contract" do
    test "payload contains all required fields for service worker" do
      payload = %{
        "title" => "#general",
        "body" => "alice: test message",
        "tag" => "channel:123",
        "url" => "/chat/general",
        "type" => "new_message"
      }

      json = WebPushAdapter.build_payload(payload)
      decoded = Jason.decode!(json)

      assert Map.has_key?(decoded, "title")
      assert Map.has_key?(decoded, "body")
      assert Map.has_key?(decoded, "tag")
      assert Map.has_key?(decoded, "url")
      assert Map.has_key?(decoded, "type")
    end
  end

  describe "subscription validation" do
    test "rejects invalid subscription JSON" do
      assert {:error, :invalid_subscription} = WebPushAdapter.decode_subscription("garbage")
    end

    test "rejects subscription missing endpoint" do
      token = Jason.encode!(%{"keys" => %{"p256dh" => "a", "auth" => "b"}})
      assert {:error, :invalid_subscription} = WebPushAdapter.decode_subscription(token)
    end

    test "accepts valid subscription" do
      token = Jason.encode!(%{
        "endpoint" => "https://push.example.com/sub/123",
        "keys" => %{"p256dh" => "publickey", "auth" => "authsecret"}
      })

      assert {:ok, _sub} = WebPushAdapter.decode_subscription(token)
    end
  end

  describe "device token platform" do
    test "accepts web_push platform" do
      user = insert(:user)
      subscription = Jason.encode!(%{endpoint: "https://push.example.com", keys: %{p256dh: "k", auth: "a"}})

      changeset = DeviceToken.changeset(%DeviceToken{}, %{
        user_id: user.id,
        token: subscription,
        platform: "web_push"
      })

      assert changeset.valid?
    end
  end
end
```

- [ ] **Step 2: Run integration tests**

Run:
```bash
mix test test/slackex/notifications/push_notifications_integration_test.exs --trace
```

- [ ] **Step 3: Run full test suite**

Run:
```bash
mix test
```
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/slackex/notifications/push_notifications_integration_test.exs
git commit -m "test(push): add integration tests for preferences, payload contract, and subscription validation"
```

---

## Post-Implementation Checklist

After all tasks are complete:

- [ ] Generate VAPID keys: `mix tenun.gen.vapid_keys`
- [ ] Add keys to production `.env` (VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY)
- [ ] Set push adapter in prod config: `config :slackex, :push_adapter, Slackex.Notifications.WebPushAdapter`
- [ ] Enable feature flag: `FunWithFlags.enable(:push_notifications)`
- [ ] Test: open profile settings, click "Enable Notifications", accept browser prompt
- [ ] Test: send a message from another user, verify notification appears
- [ ] Test: set a channel to "Mentions only", verify only @mentions trigger notifications
- [ ] Test: set a channel to "Mute", verify no notifications from that channel
- [ ] Verify Grafana: no errors from WebPushAdapter in logs
