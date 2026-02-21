# Testing Strategy — Testing Trophy

## Philosophy

We follow the **Testing Trophy** approach (Kent C. Dodds), not the traditional test pyramid. The bulk of tests are **behavioral integration tests** that exercise the system through its public APIs — the same interfaces that LiveView, Channels, and mobile clients use.

**Guiding principle:** _"The more your tests resemble the way your software is used, the more confidence they give you."_

### Test Distribution

```
         ╱╲           E2E (3-5 tests)
        ╱ 5% ╲         Critical user journeys via Wallaby
      ╱────────╲
     ╱          ╲
    ╱    75%     ╲     Behavioral Integration Tests
   ╱  Context APIs  ╲   LiveView interactions
  ╱  Channel protocol ╲  Cache cascade behavior
 ╱   Search behavior    ╲ Reconnection catch-up
╱────────────────────────╲
│      15% Unit           │ Snowflake, Permissions, RateLimiter
╠═════════════════════════╣ Pure functions only
│   5% Static Analysis    │ Dialyzer, Credo, Boundary, compiler
└─────────────────────────┘
```

### What We DON'T Test

- GenServer internal state shapes (test behavior instead)
- Ecto changeset validation in isolation (test through context API)
- Individual private functions
- Phoenix router/pipeline plumbing
- Third-party library internals

### What We DO Test

- User-meaningful behaviors through public APIs
- System behavior under realistic conditions (multiple users, concurrent messages)
- Cache cascade correctness (ETS → Redis → Postgres)
- Real-time message delivery across subscribers
- Authorization boundaries (who can do what)
- Reconnection and catch-up accuracy
- Search relevance (FTS + semantic)

## Static Analysis Layer

Zero-runtime-cost confidence. Runs on every commit via pre-commit hook and CI.

### Compiler + Boundary

```bash
mix compile --warnings-as-errors
```

This catches:
- Unused variables, imports, aliases
- Pattern match warnings
- **Boundary violations** (e.g., `Slackex.Chat` calling `SlackexWeb` directly)
- Missing function clauses
- Deprecated function usage

### Credo

```bash
mix credo --strict
```

Enforces consistent code style, catches common anti-patterns. See `05-ci-cd-devops.md` for full `.credo.exs` config.

### Dialyzer

```bash
mix dialyzer
```

Catches type mismatches, unreachable code, contract violations. Runs against the full PLT (built once, cached in CI).

## Test Support Infrastructure

### Factory (ExMachina)

```elixir
# test/support/factory.ex
defmodule Slackex.Factory do
  use ExMachina.Ecto, repo: Slackex.Repo

  alias Slackex.Accounts.User
  alias Slackex.Chat.{Channel, Message, Subscription, DMConversation, ReadCursor}

  def user_factory do
    %User{
      username: sequence(:username, &"user#{&1}"),
      display_name: sequence(:display_name, &"User #{&1}"),
      email: sequence(:email, &"user#{&1}@example.com"),
      hashed_password: Bcrypt.hash_pwd_salt("password123"),
      status: "offline"
    }
  end

  def channel_factory do
    %Channel{
      name: sequence(:channel_name, &"channel-#{&1}"),
      slug: sequence(:channel_slug, &"channel-#{&1}"),
      description: "A test channel",
      is_private: false,
      creator: build(:user)
    }
  end

  def private_channel_factory do
    struct!(channel_factory(), %{is_private: true})
  end

  def subscription_factory do
    %Subscription{
      user: build(:user),
      channel: build(:channel),
      role: "member",
      muted: false
    }
  end

  def message_factory do
    %Message{
      id: Slackex.Infrastructure.Snowflake.generate(),
      content: sequence(:content, &"Test message #{&1}"),
      sender: build(:user),
      channel: build(:channel)
    }
  end

  def dm_conversation_factory do
    user_a = build(:user)
    user_b = build(:user)
    {a, b} = if user_a.id < user_b.id, do: {user_a, user_b}, else: {user_b, user_a}

    %DMConversation{
      user_a: a,
      user_b: b
    }
  end

  def read_cursor_factory do
    %ReadCursor{
      user: build(:user),
      channel: build(:channel),
      last_read_message_id: 0
    }
  end

  # --- Helpers ---

  def with_subscription(channel, user, role \\ "member") do
    insert(:subscription, user: user, channel: channel, role: role)
    channel
  end
end
```

### Test Case Modules

```elixir
# test/support/data_case.ex
defmodule Slackex.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Slackex.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Slackex.DataCase
      import Slackex.Factory
    end
  end

  setup tags do
    Slackex.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Slackex.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
```

```elixir
# test/support/conn_case.ex
defmodule SlackexWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint SlackexWeb.Endpoint

      use SlackexWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import SlackexWeb.ConnCase
      import Slackex.Factory
    end
  end

  setup tags do
    Slackex.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def log_in_user(conn, user) do
    token = Slackex.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  def generate_token(user) do
    Slackex.Accounts.Auth.generate_api_token(user)
  end
end
```

```elixir
# test/support/channel_case.ex
defmodule SlackexWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import SlackexWeb.ChannelCase
      import Slackex.Factory

      @endpoint SlackexWeb.Endpoint
    end
  end

  setup tags do
    Slackex.DataCase.setup_sandbox(tags)
    :ok
  end

  def generate_token(user) do
    Slackex.Accounts.Auth.generate_api_token(user)
  end
end
```

## Behavioral Integration Tests

### Accounts Behavior

```elixir
# test/slackex/accounts_test.exs
defmodule Slackex.AccountsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Accounts

  describe "user registration" do
    test "valid attributes create a user" do
      assert {:ok, user} = Accounts.register_user(%{
        username: "alice",
        email: "alice@example.com",
        password: "securepassword123"
      })

      assert user.username == "alice"
      assert user.email == "alice@example.com"
      assert user.hashed_password != "securepassword123"
    end

    test "duplicate username is rejected" do
      insert(:user, username: "alice")

      assert {:error, changeset} = Accounts.register_user(%{
        username: "alice",
        email: "other@example.com",
        password: "securepassword123"
      })

      assert "has already been taken" in errors_on(changeset).username
    end

    test "weak password is rejected" do
      assert {:error, changeset} = Accounts.register_user(%{
        username: "alice",
        email: "alice@example.com",
        password: "short"
      })

      assert "should be at least 8 character(s)" in errors_on(changeset).password
    end

    test "username must be lowercase alphanumeric" do
      assert {:error, changeset} = Accounts.register_user(%{
        username: "Alice With Spaces!",
        email: "alice@example.com",
        password: "securepassword123"
      })

      assert errors_on(changeset).username != []
    end
  end

  describe "authentication" do
    test "valid credentials return the user" do
      user = insert(:user, email: "alice@example.com")

      assert found_user = Accounts.get_user_by_email_and_password(
        "alice@example.com",
        "password123"
      )

      assert found_user.id == user.id
    end

    test "wrong password returns nil" do
      insert(:user, email: "alice@example.com")

      refute Accounts.get_user_by_email_and_password("alice@example.com", "wrong")
    end

    test "session token can be generated and verified" do
      user = insert(:user)
      token = Accounts.generate_user_session_token(user)

      found_user = Accounts.get_user_by_session_token(token)
      assert found_user.id == user.id
    end

    test "deleted session token no longer works" do
      user = insert(:user)
      token = Accounts.generate_user_session_token(user)

      Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)
    end
  end
end
```

### Chat Behavior

```elixir
# test/slackex/chat_test.exs
defmodule Slackex.ChatTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  describe "channel lifecycle" do
    test "creating a channel auto-subscribes creator as owner" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "Engineering"})

      assert channel.slug == "engineering"
      assert channel.creator_id == user.id
      assert Chat.get_role(user.id, channel.id) == "owner"
    end

    test "channel slugs are unique and URL-safe" do
      user = insert(:user)
      {:ok, ch1} = Chat.create_channel(user.id, %{name: "My Channel!"})
      assert ch1.slug == "my-channel"

      {:error, _} = Chat.create_channel(user.id, %{name: "My Channel!"})
    end

    test "user can join a public channel" do
      creator = insert(:user)
      joiner = insert(:user)
      {:ok, channel} = Chat.create_channel(creator.id, %{name: "open"})

      assert {:ok, _} = Chat.join_channel(joiner.id, channel.id)
      assert Chat.get_role(joiner.id, channel.id) == "member"
      assert channel.id in Enum.map(Chat.list_user_channels(joiner.id), & &1.id)
    end

    test "user cannot join a private channel without invite" do
      creator = insert(:user)
      outsider = insert(:user)
      {:ok, channel} = Chat.create_channel(creator.id, %{name: "secret", is_private: true})

      assert {:error, :unauthorized} = Chat.join_channel(outsider.id, channel.id)
    end

    test "leaving a channel removes subscription" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "temp"})

      other = insert(:user)
      Chat.join_channel(other.id, channel.id)
      assert Chat.get_role(other.id, channel.id) == "member"

      Chat.leave_channel(other.id, channel.id)
      refute Chat.get_role(other.id, channel.id)
    end
  end

  describe "messaging behavior" do
    setup do
      alice = insert(:user, username: "alice")
      bob = insert(:user, username: "bob")
      {:ok, channel} = Chat.create_channel(alice.id, %{name: "general"})
      Chat.join_channel(bob.id, channel.id)

      %{alice: alice, bob: bob, channel: channel}
    end

    test "subscribed user can send a message", %{alice: alice, channel: channel} do
      {:ok, message} = Chat.send_message(channel.id, alice.id, "Hello everyone!")

      assert message.content == "Hello everyone!"
      assert message.sender_id == alice.id
      assert message.channel_id == channel.id
    end

    test "messages appear in channel history in order",
         %{alice: alice, bob: bob, channel: channel} do
      {:ok, m1} = Chat.send_message(channel.id, alice.id, "first")
      {:ok, m2} = Chat.send_message(channel.id, bob.id, "second")
      {:ok, m3} = Chat.send_message(channel.id, alice.id, "third")

      messages = Chat.list_messages(channel.id)
      assert Enum.map(messages, & &1.content) == ["first", "second", "third"]
      assert m1.id < m2.id and m2.id < m3.id
    end

    test "non-subscriber cannot send messages", %{channel: channel} do
      outsider = insert(:user)
      assert {:error, :unauthorized} = Chat.send_message(channel.id, outsider.id, "sneaky")
    end

    test "message content is sanitized (XSS prevention)", %{alice: alice, channel: channel} do
      {:ok, message} = Chat.send_message(
        channel.id,
        alice.id,
        "<script>alert('xss')</script>Hello"
      )

      refute message.content =~ "<script>"
      assert message.content =~ "Hello"
    end

    test "messages use Snowflake IDs (monotonically increasing)", %{alice: alice, channel: channel} do
      ids = for i <- 1..10 do
        {:ok, msg} = Chat.send_message(channel.id, alice.id, "msg #{i}")
        msg.id
      end

      assert ids == Enum.sort(ids)
      assert Enum.all?(ids, &is_integer/1)
      assert Enum.all?(ids, &(&1 > 0))
    end
  end

  describe "unread tracking" do
    setup do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, channel} = Chat.create_channel(alice.id, %{name: "general"})
      Chat.join_channel(bob.id, channel.id)

      %{alice: alice, bob: bob, channel: channel}
    end

    test "unread count reflects messages since last read",
         %{alice: alice, bob: bob, channel: channel} do
      Chat.mark_as_read(bob.id, channel.id)

      Chat.send_message(channel.id, alice.id, "msg 1")
      Chat.send_message(channel.id, alice.id, "msg 2")
      Chat.send_message(channel.id, alice.id, "msg 3")

      assert Chat.unread_count(bob.id, channel.id) == 3
    end

    test "marking as read resets unread count",
         %{alice: alice, bob: bob, channel: channel} do
      Chat.send_message(channel.id, alice.id, "msg 1")
      assert Chat.unread_count(bob.id, channel.id) >= 1

      Chat.mark_as_read(bob.id, channel.id)
      assert Chat.unread_count(bob.id, channel.id) == 0
    end

    test "new channel has zero unread", %{bob: bob, channel: channel} do
      assert Chat.unread_count(bob.id, channel.id) == 0
    end
  end

  describe "direct messages" do
    test "two users can start a DM conversation" do
      alice = insert(:user)
      bob = insert(:user)

      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)
      assert dm.user_a_id == min(alice.id, bob.id)
      assert dm.user_b_id == max(alice.id, bob.id)
    end

    test "DM conversation is the same regardless of who initiates" do
      alice = insert(:user)
      bob = insert(:user)

      {:ok, dm1} = Chat.find_or_create_dm(alice.id, bob.id)
      {:ok, dm2} = Chat.find_or_create_dm(bob.id, alice.id)

      assert dm1.id == dm2.id
    end

    test "DM messages are persisted and retrievable" do
      alice = insert(:user)
      bob = insert(:user)

      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)
      {:ok, _msg} = Chat.send_dm(dm.id, alice.id, "Hey Bob!")

      dms = Chat.list_dms(bob.id)
      assert length(dms) == 1
    end

    test "only DM participants can send messages" do
      alice = insert(:user)
      bob = insert(:user)
      outsider = insert(:user)

      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      # Participants can send
      assert {:ok, _} = Chat.send_dm(dm.id, alice.id, "From Alice")
      assert {:ok, _} = Chat.send_dm(dm.id, bob.id, "From Bob")

      # Non-participant is rejected
      assert {:error, :unauthorized} = Chat.send_dm(dm.id, outsider.id, "Sneaky!")
    end
  end
end
```

### LiveView Behavioral Tests

```elixir
# test/slackex_web/live/chat_live_test.exs
defmodule SlackexWeb.ChatLiveTest do
  use SlackexWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "chat experience" do
    setup %{conn: conn} do
      alice = insert(:user, username: "alice")
      bob = insert(:user, username: "bob")
      {:ok, general} = Slackex.Chat.create_channel(alice.id, %{name: "general"})
      Slackex.Chat.join_channel(bob.id, general.id)

      %{conn: log_in_user(conn, alice), alice: alice, bob: bob, channel: general}
    end

    test "user sees their channels in sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      assert has_element?(view, "[data-role=channel-item]", "general")
    end

    test "selecting a channel shows its messages",
         %{conn: conn, bob: bob, channel: channel} do
      Slackex.Chat.send_message(channel.id, bob.id, "Welcome!")

      {:ok, view, _html} = live(conn, ~p"/chat/general")
      assert has_element?(view, "[data-role=message]", "Welcome!")
    end

    test "sending a message makes it appear", %{conn: conn, channel: _channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#message-form", %{content: "Hello from test!"})
      |> render_submit()

      assert has_element?(view, "[data-role=message]", "Hello from test!")
    end

    test "real-time message from another user appears",
         %{conn: conn, bob: bob, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      # Simulate Bob sending a message via PubSub
      Slackex.Chat.send_message(channel.id, bob.id, "Hello from Bob!")

      # LiveView should receive via handle_info
      assert has_element?(view, "[data-role=message]", "Hello from Bob!")
    end

    test "unauthenticated user is redirected to login" do
      conn = build_conn()
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/chat")
    end
  end
end
```

### Channel (Mobile) Behavioral Tests

```elixir
# test/slackex_web/channels/chat_channel_test.exs
defmodule SlackexWeb.ChatChannelTest do
  use SlackexWeb.ChannelCase, async: true

  describe "mobile chat experience" do
    setup do
      alice = insert(:user, username: "alice")
      bob = insert(:user, username: "bob")
      {:ok, channel} = Slackex.Chat.create_channel(alice.id, %{name: "general"})
      Slackex.Chat.join_channel(bob.id, channel.id)

      {:ok, alice_socket} = connect(SlackexWeb.UserSocket, %{
        "token" => generate_token(alice)
      })
      {:ok, bob_socket} = connect(SlackexWeb.UserSocket, %{
        "token" => generate_token(bob)
      })

      %{
        alice_socket: alice_socket,
        bob_socket: bob_socket,
        alice: alice,
        bob: bob,
        channel: channel
      }
    end

    test "joining a channel succeeds for subscribers",
         %{alice_socket: socket, channel: channel} do
      {:ok, reply, _socket} = subscribe_and_join(socket, "chat:#{channel.id}", %{})
      assert is_list(reply.messages)
    end

    test "joining returns recent message history",
         %{alice_socket: socket, alice: alice, channel: channel} do
      for i <- 1..5 do
        Slackex.Chat.send_message(channel.id, alice.id, "msg #{i}")
      end

      {:ok, reply, _socket} = subscribe_and_join(socket, "chat:#{channel.id}", %{})
      assert length(reply.messages) == 5
    end

    test "sending a message broadcasts to channel",
         %{alice_socket: alice_socket, channel: channel} do
      {:ok, _, socket} = subscribe_and_join(alice_socket, "chat:#{channel.id}", %{})

      push(socket, "new_message", %{"content" => "hello from mobile"})
      assert_broadcast "new_message", %{content: "hello from mobile"}
    end

    test "unauthorized user cannot join private channel" do
      outsider = insert(:user)
      private = insert(:channel, is_private: true)

      {:ok, socket} = connect(SlackexWeb.UserSocket, %{
        "token" => generate_token(outsider)
      })

      assert {:error, %{reason: "unauthorized"}} =
        subscribe_and_join(socket, "chat:#{private.id}", %{})
    end

    test "invalid token rejects connection" do
      assert :error = connect(SlackexWeb.UserSocket, %{"token" => "invalid"})
    end
  end
end
```

### Search Behavioral Tests

```elixir
# test/slackex/search_test.exs
defmodule Slackex.SearchTest do
  use Slackex.DataCase, async: true

  alias Slackex.{Chat, Search}

  describe "full-text search" do
    setup do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "engineering"})

      Chat.send_message(channel.id, user.id, "Let's deploy the new API to production")
      Chat.send_message(channel.id, user.id, "The weather is nice today")
      Chat.send_message(channel.id, user.id, "Production deployment scheduled for Friday")
      Chat.send_message(channel.id, user.id, "Who wants coffee?")

      %{channel: channel, user: user}
    end

    test "finds messages matching keywords", %{channel: channel} do
      {:ok, results} = Search.search_messages("deploy production", mode: :text, channel_id: channel.id)

      contents = Enum.map(results, & &1.content)
      assert Enum.any?(contents, &(&1 =~ "deploy"))
      assert Enum.any?(contents, &(&1 =~ "deployment"))
      refute Enum.any?(contents, &(&1 =~ "coffee"))
    end

    test "returns empty list for no matches", %{channel: channel} do
      {:ok, results} = Search.search_messages("nonexistent query xyz", mode: :text, channel_id: channel.id)
      assert results == []
    end

    test "search can be scoped to a specific channel" do
      user = insert(:user)
      {:ok, other} = Chat.create_channel(user.id, %{name: "random"})
      Chat.send_message(other.id, user.id, "deploy something here too")

      {:ok, results} = Search.search_messages("deploy", mode: :text, channel_id: other.id)
      assert length(results) == 1
    end
  end
end
```

### Cache Behavioral Tests (Phase 2+)

```elixir
# test/slackex/cache_test.exs
defmodule Slackex.CacheTest do
  use Slackex.DataCase, async: false  # ETS is shared state

  alias Slackex.Cache

  describe "cache cascade behavior" do
    test "cache miss falls through to database" do
      user = insert(:user)
      {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "test"})
      Slackex.Chat.send_message(channel.id, user.id, "persisted message")

      # Cache is empty — should fall through to DB
      messages = Slackex.Search.HistoryLoader.recent(channel.id, 10)
      assert length(messages) == 1
      assert hd(messages).content == "persisted message"
    end

    test "subsequent reads come from cache" do
      user = insert(:user)
      {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "test"})
      Slackex.Chat.send_message(channel.id, user.id, "cached message")

      # First read backfills cache
      _messages = Slackex.Search.HistoryLoader.recent(channel.id, 10)

      # Second read should hit ETS
      {:ok, cached} = Cache.get_recent_messages(channel.id)
      assert length(cached) >= 1
    end

    test "cache invalidation forces DB re-read" do
      user = insert(:user)
      {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "test"})
      Slackex.Chat.send_message(channel.id, user.id, "message")

      # Populate cache
      _messages = Slackex.Search.HistoryLoader.recent(channel.id, 10)

      # Invalidate
      Cache.invalidate(channel.id)

      # Should be a miss now
      {:miss, _} = Cache.get_recent_messages(channel.id)
    end
  end
end
```

## Unit Tests (Pure Functions Only)

```elixir
# test/slackex/infrastructure/snowflake_test.exs
defmodule Slackex.Infrastructure.SnowflakeTest do
  use ExUnit.Case, async: true

  alias Slackex.Infrastructure.Snowflake

  test "generates unique IDs" do
    ids = for _ <- 1..1_000, do: Snowflake.generate()
    assert length(Enum.uniq(ids)) == 1_000
  end

  test "IDs are monotonically increasing" do
    ids = for _ <- 1..100, do: Snowflake.generate()
    assert ids == Enum.sort(ids)
  end

  test "IDs are positive 64-bit integers" do
    id = Snowflake.generate()
    assert is_integer(id)
    assert id > 0
    assert id < 1 <<< 63
  end

  test "timestamp can be extracted from ID" do
    before_ms = System.system_time(:millisecond)
    id = Snowflake.generate()
    after_ms = System.system_time(:millisecond)

    ts = Snowflake.extract_timestamp(id)
    assert ts >= before_ms
    assert ts <= after_ms
  end
end
```

```elixir
# test/slackex/chat/permissions_test.exs
defmodule Slackex.Chat.PermissionsTest do
  use ExUnit.Case, async: true

  alias Slackex.Chat.Permissions

  test "owners can do everything" do
    assert Permissions.can?("owner", :send_message)
    assert Permissions.can?("owner", :manage_channel)
    assert Permissions.can?("owner", :delete_channel)
    assert Permissions.can?("owner", :read_messages)
  end

  test "admins can manage but not delete" do
    assert Permissions.can?("admin", :send_message)
    assert Permissions.can?("admin", :manage_channel)
    refute Permissions.can?("admin", :delete_channel)
  end

  test "members can send and read" do
    assert Permissions.can?("member", :send_message)
    assert Permissions.can?("member", :read_messages)
    refute Permissions.can?("member", :manage_channel)
    refute Permissions.can?("member", :delete_channel)
  end

  test "viewers can only read" do
    refute Permissions.can?("viewer", :send_message)
    assert Permissions.can?("viewer", :read_messages)
    refute Permissions.can?("viewer", :manage_channel)
  end

  test "nil role has no permissions" do
    refute Permissions.can?(nil, :send_message)
    refute Permissions.can?(nil, :read_messages)
  end
end
```

```elixir
# test/slackex/infrastructure/rate_limiter_test.exs
defmodule Slackex.Infrastructure.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Slackex.Infrastructure.RateLimiter

  test "allows requests within rate limit" do
    limiter = RateLimiter.new(rate: 5, per: :second)

    results = for _ <- 1..5 do
      {result, limiter} = RateLimiter.check(limiter)
      result
    end

    assert Enum.all?(results, &(&1 == :ok))
  end

  test "rejects requests exceeding rate limit" do
    limiter = RateLimiter.new(rate: 2, per: :second)

    {:ok, limiter} = RateLimiter.check(limiter)
    {:ok, limiter} = RateLimiter.check(limiter)
    assert {:error, :rate_limited} = elem(RateLimiter.check(limiter), 0)
  end

  test "tokens refill after the time window elapses" do
    limiter = RateLimiter.new(rate: 1, per: :second)

    {:ok, limiter} = RateLimiter.check(limiter)
    {:error, :rate_limited} = elem(RateLimiter.check(limiter), 0)

    # Simulate time passing (the pure functional limiter uses timestamps)
    Process.sleep(1_100)

    # Should be allowed again after refill
    assert {:ok, _limiter} = RateLimiter.check(limiter)
  end

  test "rate limiter is independent per instance" do
    limiter_a = RateLimiter.new(rate: 1, per: :second)
    limiter_b = RateLimiter.new(rate: 1, per: :second)

    {:ok, _limiter_a} = RateLimiter.check(limiter_a)
    # limiter_b is unaffected by limiter_a's usage
    assert {:ok, _limiter_b} = RateLimiter.check(limiter_b)
  end
end
```

## E2E Tests (Critical Journeys Only)

```elixir
# test/e2e/chat_flow_test.exs
defmodule SlackexWeb.E2E.ChatFlowTest do
  use SlackexWeb.FeatureCase

  @tag :e2e
  test "register → create channel → send message → other user sees it" do
    # Alice registers
    alice = start_session("alice")
    visit(alice, "/users/register")
    fill_in(alice, text_field("Username"), with: "alice_e2e")
    fill_in(alice, text_field("Email"), with: "alice_e2e@test.com")
    fill_in(alice, text_field("Password"), with: "securepassword123")
    click(alice, button("Register"))

    # Alice creates a channel
    visit(alice, "/chat")
    click(alice, button("Create Channel"))
    fill_in(alice, text_field("Channel name"), with: "e2e-test")
    click(alice, button("Create"))
    assert_has(alice, css("[data-role=channel-item]", text: "e2e-test"))

    # Bob registers and joins
    bob = start_session("bob")
    register_user(bob, "bob_e2e", "bob_e2e@test.com")
    visit(bob, "/chat")
    click(bob, button("Browse Channels"))
    click(bob, css("[data-role=join-channel]", text: "e2e-test"))

    # Alice sends a message
    click(alice, css("[data-role=channel-item]", text: "e2e-test"))
    fill_in(alice, text_field("message"), with: "Hello from E2E!")
    send_keys(alice, [:enter])

    # Bob sees it
    click(bob, css("[data-role=channel-item]", text: "e2e-test"))
    assert_has(bob, css("[data-role=message]", text: "Hello from E2E!"))
  end

  @tag :e2e
  test "direct message flow" do
    alice = register_and_login("alice_dm", "alice_dm@test.com")
    bob = register_and_login("bob_dm", "bob_dm@test.com")

    # Alice starts a DM with Bob
    visit(alice, "/chat")
    click(alice, button("New Message"))
    fill_in(alice, text_field("Search users"), with: "bob_dm")
    click(alice, css("[data-role=user-result]", text: "bob_dm"))

    fill_in(alice, text_field("message"), with: "Hey Bob, private message!")
    send_keys(alice, [:enter])

    # Bob sees the DM notification
    visit(bob, "/chat")
    assert_has(bob, css("[data-role=dm-item]", text: "alice_dm"))
    click(bob, css("[data-role=dm-item]", text: "alice_dm"))
    assert_has(bob, css("[data-role=message]", text: "Hey Bob, private message!"))
  end
end
```

## Distributed Tests (Phase 3)

```elixir
# test/slackex/distributed_test.exs
defmodule Slackex.DistributedTest do
  use ExUnit.Case

  @moduletag :distributed
  @moduletag timeout: 30_000

  setup do
    nodes = LocalCluster.start_nodes("slackex", 3,
      applications: [:slackex]
    )

    on_exit(fn -> LocalCluster.stop_nodes(nodes) end)

    %{nodes: nodes}
  end

  test "channel process exists on exactly one node", %{nodes: nodes} do
    channel_id = 42

    # Start channel on first node
    :rpc.call(hd(nodes), Slackex.Messaging.ChannelSupervisor, :ensure_started, [channel_id])

    # Should be findable from ALL nodes
    for node <- nodes do
      assert {:ok, _pid} = :rpc.call(
        node,
        Slackex.Messaging.ChannelRegistry,
        :lookup,
        [channel_id]
      )
    end
  end

  test "channel process migrates on node failure", %{nodes: [n1, n2, n3]} do
    channel_id = 99

    :rpc.call(n1, Slackex.Messaging.ChannelSupervisor, :ensure_started, [channel_id])
    {:ok, original_pid} = :rpc.call(n1, Slackex.Messaging.ChannelRegistry, :lookup, [channel_id])
    original_node = node(original_pid)

    # Kill the node hosting the channel
    LocalCluster.stop_nodes([original_node])
    Process.sleep(3_000)  # Allow Horde handoff

    # Channel should be restarted on a surviving node
    surviving = [n1, n2, n3] -- [original_node]

    assert {:ok, new_pid} = :rpc.call(
      hd(surviving),
      Slackex.Messaging.ChannelRegistry,
      :lookup,
      [channel_id]
    )
    assert node(new_pid) != original_node
  end
end
```

## Test Configuration

```elixir
# config/test.exs
import Config

config :slackex, Slackex.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "slackex_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :slackex, SlackexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_purposes_only",
  server: false

config :logger, level: :warning

# Oban: inline mode for synchronous test execution
config :slackex, Oban, testing: :inline

# Use stub embedding client
config :slackex, :embedding_client, Slackex.Embeddings.StubClient

# Bcrypt: reduce rounds for faster tests
config :bcrypt_elixir, :log_rounds, 4

# Disable clustering in tests
config :libcluster, topologies: []
```

```elixir
# test/test_helper.exs
ExUnit.start(
  exclude: [:e2e, :distributed],
  capture_log: true
)

Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, :manual)
```

### Running Test Subsets

```bash
# All tests (excludes :e2e and :distributed by default)
mix test

# Include E2E tests
mix test --include e2e

# Include distributed tests
mix test --include distributed

# Run specific test file
mix test test/slackex/chat_test.exs

# Run tests matching a tag
mix test --only search

# Run with coverage report
mix test --cover

# Run in parallel (default — async: true tests)
mix test
```

## Acceptance Criteria

- [ ] All test support modules (Factory, DataCase, ConnCase, ChannelCase) are configured
- [ ] ExMachina factories exist for all schemas (User, Channel, Message, etc.)
- [ ] Behavioral integration tests cover: registration, auth, channel CRUD, messaging, DMs (including sender authorization), unread tracking
- [ ] LiveView tests verify: channel selection, message sending, real-time delivery, auth redirect
- [ ] Channel tests verify: join, send, broadcast, auth rejection
- [ ] Search tests verify: FTS keyword matching, scoping by channel
- [ ] Cache tests verify: miss fallthrough, cache population, invalidation
- [ ] Unit tests cover only: Snowflake, Permissions, RateLimiter (pure functions, including token refill behavior)
- [ ] E2E tests cover: full registration→chat flow, DM flow
- [ ] Distributed tests cover: single-writer guarantee, node failover
- [ ] Test config uses: SQL Sandbox, inline Oban, stub embeddings, reduced bcrypt rounds
- [ ] `mix test` runs all standard tests (excluding :e2e and :distributed)
- [ ] `mix test --include e2e` runs browser tests
- [ ] `mix test --include distributed` runs cluster tests
- [ ] Tests run in parallel where possible (async: true)
