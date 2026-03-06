# Test Gap Remediation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fill the two remaining gaps in the testing strategy: contract test tagging with CI step, and multi-session E2E tests using LiveView.

**Architecture:** Tag existing contract test files with `@moduletag :contract` and add a dedicated CI step. Write 2 multi-session LiveView E2E tests covering the critical user journeys (channel messaging and DM request flow).

**Tech Stack:** ExUnit, Phoenix LiveView test helpers, Phoenix PubSub, existing ConnCase/ChannelCase

---

### Task 1: Tag Contract Tests

**Files:**
- Modify: `test/slackex_web/channels/envelope_contract_test.exs`
- Modify: `test/slackex_web/controllers/api/auth_controller_test.exs`
- Modify: `test/slackex_web/controllers/api/bootstrap_controller_test.exs`
- Modify: `test/slackex_web/controllers/api/serializer_test.exs`
- Modify: `test/slackex_web/controllers/api/device_token_controller_test.exs`

**Step 1: Add `@moduletag :contract` to each test file**

Add the tag after the `use` statement in each file. For example in `envelope_contract_test.exs`:

```elixir
defmodule SlackexWeb.Channels.EnvelopeContractTest do
  @moduledoc """
  Contract tests for the versioned envelope protocol.
  ...
  """

  use SlackexWeb.ChannelCase, async: false
  @moduletag :contract

  # ... rest of file unchanged
```

Do the same for the other 4 files, adding `@moduletag :contract` on the line after the `use` statement.

For `auth_controller_test.exs`, `bootstrap_controller_test.exs`, `serializer_test.exs`, and `device_token_controller_test.exs`:

```elixir
use SlackexWeb.ConnCase, async: true
@moduletag :contract
```

**Step 2: Verify contract tests can be run in isolation**

Run: `mix test --only contract`
Expected: Only the 5 tagged files run, all pass.

**Step 3: Verify default suite still includes them**

Run: `mix test`
Expected: 1089 tests (same count — no tests excluded), 0 failures.

**Step 4: Commit**

```bash
git add test/slackex_web/channels/envelope_contract_test.exs \
        test/slackex_web/controllers/api/auth_controller_test.exs \
        test/slackex_web/controllers/api/bootstrap_controller_test.exs \
        test/slackex_web/controllers/api/serializer_test.exs \
        test/slackex_web/controllers/api/device_token_controller_test.exs
git commit -m "test: tag contract tests with @moduletag :contract"
```

---

### Task 2: Add Contract Test CI Step

**Files:**
- Modify: `.github/workflows/ci-deploy.yml:94-95`

**Step 1: Add contract test step after the general test step**

In `.github/workflows/ci-deploy.yml`, after the existing `Tests` step (line 94-95), add:

```yaml
      - name: Contract tests
        run: mix test --only contract --warnings-as-errors
```

This goes between the `Tests` step and the `Hex audit` step.

**Step 2: Verify YAML is valid**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci-deploy.yml'))"`
Expected: No error output.

**Step 3: Commit**

```bash
git add .github/workflows/ci-deploy.yml
git commit -m "ci: add dedicated contract test step"
```

---

### Task 3: Write E2E Test — Channel Messaging Flow

**Files:**
- Create: `test/slackex_web/live/chat_live/e2e_test.exs`

**Step 1: Write the test file with channel messaging E2E test**

```elixir
defmodule SlackexWeb.ChatLive.E2ETest do
  @moduledoc """
  Multi-session E2E tests using LiveView test helpers.
  Verifies critical user journeys across multiple connected users.
  """

  use SlackexWeb.ConnCase, async: false
  @moduletag :e2e

  alias Slackex.Chat

  describe "channel messaging flow" do
    test "user sends message and another user sees it in real-time", %{conn: conn} do
      # Setup: two users, one channel
      alice = insert(:user, username: "alice_e2e")
      bob = insert(:user, username: "bob_e2e")

      {:ok, channel} =
        Chat.create_channel(alice.id, %{name: "e2e-general", description: "E2E test"})

      Chat.join_channel(bob.id, channel.id)

      # Alice connects to the channel
      alice_conn = log_in_user(conn, alice)
      {:ok, alice_view, alice_html} = live(alice_conn, ~p"/chat/#{channel.slug}")

      # Alice sees the channel
      assert alice_html =~ "#e2e-general"

      # Bob connects to the same channel
      bob_conn = Phoenix.ConnTest.build_conn() |> log_in_user(bob)
      {:ok, bob_view, _bob_html} = live(bob_conn, ~p"/chat/#{channel.slug}")

      # Alice sends a message
      alice_view
      |> form("#message-form", message: %{content: "Hello from Alice!"})
      |> render_submit()

      # Bob should see Alice's message via PubSub
      # Give PubSub a moment to deliver through ChannelServer pipeline
      Process.sleep(100)
      bob_html = render(bob_view)

      assert bob_html =~ "Hello from Alice!"
    end
  end
end
```

**Step 2: Run the test**

Run: `mix test test/slackex_web/live/chat_live/e2e_test.exs --include e2e`
Expected: 1 test, 0 failures.

Note: The `@moduletag :e2e` tag means this test is excluded from `mix test` by default (`:e2e` is in the ExUnit excludes in `test_helper.exs`). You must use `--include e2e` to run it.

**Step 3: Commit**

```bash
git add test/slackex_web/live/chat_live/e2e_test.exs
git commit -m "test(e2e): add channel messaging flow E2E test"
```

---

### Task 4: Write E2E Test — DM Request Flow

**Files:**
- Modify: `test/slackex_web/live/chat_live/e2e_test.exs`

**Step 1: Add DM request flow test**

Add a new `describe` block to the existing `e2e_test.exs`:

```elixir
  describe "DM request flow" do
    test "alice sends DM request, bob accepts, messages flow between them", %{conn: conn} do
      alice = insert(:user, username: "alice_dm_e2e")
      bob = insert(:user, username: "bob_dm_e2e", dm_preference: "anyone")

      # Alice connects
      alice_conn = log_in_user(conn, alice)
      {:ok, alice_view, _html} = live(alice_conn, ~p"/chat")

      # Alice creates a DM request to bob
      {:ok, request} = Chat.create_dm_request(alice.id, bob.id, "Hey Bob!")

      # Bob connects and sees the request
      bob_conn = Phoenix.ConnTest.build_conn() |> log_in_user(bob)
      {:ok, bob_view, bob_html} = live(bob_conn, ~p"/chat")

      # Bob should see the DM request in sidebar (via PubSub or initial load)
      Process.sleep(100)
      bob_html = render(bob_view)
      assert bob_html =~ "Message Requests" or bob_html =~ "alice_dm_e2e"

      # Bob accepts the request
      {:ok, dm} = Chat.accept_dm_request(request.id, bob.id)

      # Alice navigates to the DM
      {:ok, alice_dm_view, _html} = live(alice_conn, ~p"/chat/dm/#{dm.id}")

      # Alice sends a message in the DM
      alice_dm_view
      |> form("#message-form", message: %{content: "Thanks for accepting!"})
      |> render_submit()

      # Bob navigates to the DM and sees the message
      {:ok, _bob_dm_view, bob_dm_html} = live(bob_conn, ~p"/chat/dm/#{dm.id}")
      assert bob_dm_html =~ "Thanks for accepting!"
    end
  end
```

**Step 2: Run both E2E tests**

Run: `mix test test/slackex_web/live/chat_live/e2e_test.exs --include e2e`
Expected: 2 tests, 0 failures.

**Step 3: Run the full suite to verify nothing is broken**

Run: `mix test`
Expected: 1089 tests, 0 failures (E2E tests excluded by default).

**Step 4: Commit**

```bash
git add test/slackex_web/live/chat_live/e2e_test.exs
git commit -m "test(e2e): add DM request flow E2E test"
```

---

### Task 5: Final Verification and Push

**Step 1: Verify contract tests run in isolation**

Run: `mix test --only contract`
Expected: All contract tests pass (5 files).

**Step 2: Verify E2E tests run in isolation**

Run: `mix test --include e2e`
Expected: All tests pass including the 2 new E2E tests.

**Step 3: Verify default suite is unchanged**

Run: `mix test`
Expected: 1089 tests, 0 failures (E2E excluded, contract included).

**Step 4: Push**

```bash
git push origin master
```
