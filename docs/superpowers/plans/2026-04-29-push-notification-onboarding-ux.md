# Push Notification Onboarding UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the five-layer permission/install/cache friction that almost lost a real user (the project owner) to silent push failures. Make notification setup obvious, recoverable, and self-verifying.

**Architecture:** Server-side endpoint for the test push (so the JS hook can trigger a real end-to-end delivery), plus three new front-end touchpoints (pre-prompt modal, test button, persistent health badge). All gated behind the existing `:push_notifications` flag — no new flag needed.

**Tech Stack:** Phoenix LiveView events, Plug-served `priv/static/service-worker.js`, web_push_elixir, FunWithFlags, daisyUI/Tailwind, existing `WebPushAdapter`.

**Background — friction map of the current journey**

```
Visit site → install PWA?     (most users won't know to)
   → grant browser prompt     (one-shot — accidental "block" is forever)
       → grant OS permission  (silent until you know to look)
           → disable battery saver / Doze
               → maybe it works
```

Five gates, only one ever surfaced in the app. Each fails silently. The UI also actively lied: the "Enabled" badge in Edit Profile was driven solely by `pushManager.getSubscription()` and continued to claim "Enabled" even when `Notification.permission === "default"` (fixed in v0.9.13 but only the symptom).

---

## Captured options (all tiers)

### Tier 1 — small, high-leverage (this plan implements these)

1. **Pre-prompt explainer.** Custom modal before `Notification.requestPermission()` so accidental denials don't permanently brick notifications for that user.
2. **Send-and-verify button.** "Send test notification" in Edit Profile that fires a real push from the server to the user's own tokens. Closes the loop visually.
3. **Live health badge.** Small persistent indicator that lights up when push subscription is incomplete. Replaces the lying "Enabled" badge with one that reflects reality.

### Tier 2 — larger, ship after Tier 1 has bedded in

4. **First-mount onboarding.** One-time card after a user's first message inviting them to set up notifications.
5. **Install-Tenun CTA.** Surface `beforeinstallprompt` as an in-app install button so users get a real WebAPK / standalone PWA identity.
6. **Permission troubleshooter.** Auto-test after subscribe; on failure show a UA-detected wizard ("You're on macOS Chrome — open System Settings → Notifications → Google Chrome").

### Tier 3 — long term

7. **Per-platform docs page** at `/help/notifications` with annotated screenshots for macOS Chrome, Android Chrome, iOS Safari 16.4+.

---

## Tier 1 — File Map

**Create:**
- `lib/slackex/notifications/test_push.ex` — pure module that builds a test payload + dispatches via `WebPushAdapter` to all of a user's `DeviceToken`s.
- `test/slackex/notifications/test_push_test.exs`
- `test/slackex_web/live/chat_live/health_badge_test.exs`

**Modify:**
- `assets/js/hooks/push_subscription.js` — pre-prompt explainer + emit a `push:test_sent` event for round-trip verification.
- `lib/slackex_web/live/chat_live/index.ex` — `send_test_push` event handler, new `:push_health` assign sourced from `push_subscribed`/`push_permission`.
- `lib/slackex_web/components/chat_components.ex` — pre-prompt modal markup + test button + health badge; "Enabled" badge now sourced from `push_health == :ok`.
- `lib/slackex_web/live/chat_live/index.html.heex` — render the health badge in the avatar/header area.

---

## Tier 1 — Tasks

### Task 1: TestPush module (TDD)

**Files:**
- Create: `lib/slackex/notifications/test_push.ex`
- Create: `test/slackex/notifications/test_push_test.exs`

The module fans out a test payload across every `DeviceToken` for the given `user_id` via the configured push adapter, returning `{:ok, sent_count}` or `{:error, reason}`.

- [ ] **Step 1: Write the failing test**

  ```elixir
  defmodule Slackex.Notifications.TestPushTest do
    use Slackex.DataCase, async: false
    import Slackex.TestFactory

    alias Slackex.Notifications.TestPush

    setup do
      Process.put(:push_test_pid, self())
      :ok
    end

    test "returns {:ok, 0} when the user has no tokens" do
      user = insert(:user)
      assert {:ok, 0} = TestPush.send(user.id)
      refute_received {:stub_push_sent, _, _}
    end

    test "fans out to every token registered for the user" do
      user = insert(:user)
      insert(:device_token, user: user, token: "token-a", platform: "web_push")
      insert(:device_token, user: user, token: "token-b", platform: "web_push")
      other = insert(:user)
      insert(:device_token, user: other, token: "token-other", platform: "web_push")

      assert {:ok, 2} = TestPush.send(user.id)

      assert_received {:stub_push_sent, "token-a", payload}
      assert_received {:stub_push_sent, "token-b", _}
      refute_received {:stub_push_sent, "token-other", _}
      assert payload["title"] == "Tenun test notification"
      assert payload["type"] == "test"
    end

    test "returns {:error, reason} when adapter fails on every token" do
      original = Application.get_env(:slackex, :push_adapter)
      Application.put_env(:slackex, :push_adapter, AlwaysFailAdapter)
      on_exit(fn -> Application.put_env(:slackex, :push_adapter, original) end)

      user = insert(:user)
      insert(:device_token, user: user, token: "token-a", platform: "web_push")

      assert {:error, _} = TestPush.send(user.id)
    end
  end

  defmodule AlwaysFailAdapter do
    def send_push(_token, _platform, _payload), do: {:error, :boom}
  end
  ```

- [ ] **Step 2: Run, expect failure**

  ```
  mix test test/slackex/notifications/test_push_test.exs
  ```
  Expected: 3 failures — module undefined.

- [ ] **Step 3: Implement TestPush**

  ```elixir
  defmodule Slackex.Notifications.TestPush do
    @moduledoc """
    Fires a synthetic push to every device token registered for a user. Used
    by the in-app "Send test notification" button so users can verify their
    full push path end-to-end without waiting for a real message.
    """

    import Ecto.Query

    alias Slackex.Notifications.DeviceToken
    alias Slackex.Repo

    @spec send(integer()) :: {:ok, non_neg_integer()} | {:error, term()}
    def send(user_id) do
      tokens =
        Repo.all(
          from dt in DeviceToken,
            where: dt.user_id == ^user_id,
            select: %{token: dt.token, platform: dt.platform}
        )

      adapter = Application.get_env(:slackex, :push_adapter, Slackex.Notifications.PushAdapter.Stub)
      payload = build_payload()

      results = Enum.map(tokens, &adapter.send_push(&1.token, &1.platform, payload))

      cond do
        results == [] -> {:ok, 0}
        Enum.all?(results, &(&1 == :ok)) -> {:ok, length(results)}
        true -> {:error, Enum.find(results, &(elem(&1, 0) == :error))}
      end
    end

    defp build_payload do
      %{
        "title" => "Tenun test notification",
        "body" => "If you see this, push notifications are working.",
        "tag" => "tenun-test",
        "url" => "/chat",
        "type" => "test"
      }
    end
  end
  ```

- [ ] **Step 4: Re-run, all green**

- [ ] **Step 5: Commit**

  ```bash
  git add lib/slackex/notifications/test_push.ex test/slackex/notifications/test_push_test.exs
  git commit -m "feat(push): TestPush module fans a synthetic payload to all of a user's tokens"
  ```

### Task 2: LiveView event handler + test button

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex` — add `handle_event("send_test_push", ...)`.
- Modify: `lib/slackex_web/components/chat_components.ex` — render a "Send test notification" button next to the existing Enabled/Disable controls in `edit_profile_modal/1`.

- [ ] **Step 1: Read current Edit Profile modal markup** (around `chat_components.ex:903-940`).

- [ ] **Step 2: Add handler in `lib/slackex_web/live/chat_live/index.ex`** alongside the other push handlers (around `index.ex:875-905`):

  ```elixir
  def handle_event("send_test_push", _params, socket) do
    user = socket.assigns.current_user

    socket =
      case Slackex.Notifications.TestPush.send(user.id) do
        {:ok, 0} ->
          put_flash(socket, :error, "No registered devices — enable notifications first.")

        {:ok, n} ->
          put_flash(socket, :info, "Test notification sent to #{n} device#{if n == 1, do: "", else: "s"}. Check your OS notification centre.")

        {:error, reason} ->
          require Logger
          Logger.warning("send_test_push failed for user #{user.id}: #{inspect(reason)}")
          put_flash(socket, :error, "Couldn't send test notification — see browser console.")
      end

    {:noreply, socket}
  end
  ```

- [ ] **Step 3: Add the button in `chat_components.ex`** inside the `<%= if @push_subscribed do %>` branch, after the "Disable" button:

  ```heex
  <button
    type="button"
    phx-click="send_test_push"
    class="btn btn-sm btn-ghost"
  >
    Send test notification
  </button>
  ```

- [ ] **Step 4: Manual smoke** — load `/chat` in dev, open Edit Profile, click "Send test notification". Flash should report success or "no devices".

- [ ] **Step 5: Commit**

  ```bash
  git add lib/slackex_web/live/chat_live/index.ex lib/slackex_web/components/chat_components.ex
  git commit -m "feat(push): in-app 'Send test notification' button"
  ```

### Task 3: Pre-prompt explainer

**Files:**
- Modify: `assets/js/hooks/push_subscription.js` — interpose a custom modal before calling `Notification.requestPermission()`.
- Modify: `lib/slackex_web/components/chat_components.ex` — render a `<dialog>` element keyed off a new `@show_push_explainer` assign.
- Modify: `lib/slackex_web/live/chat_live/index.ex` — toggle the explainer; on confirm, push the existing `push:subscribe` event.

The explainer prevents the destructive "click block by accident" failure mode: once a browser registers `denied`, the user can't un-deny without site-settings spelunking. The custom dialog uses a user-gesture confirm before the browser prompt fires.

- [ ] **Step 1: Add `:show_push_explainer` assign to mount** in `index.ex` (false by default).

- [ ] **Step 2: Change the existing `enable_push` handler** to set `show_push_explainer: true` instead of pushing `push:subscribe` immediately:

  ```elixir
  def handle_event("enable_push", _params, socket) do
    if socket.assigns.push_permission == "granted" and socket.assigns.push_subscribed do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :show_push_explainer, true)}
    end
  end

  def handle_event("confirm_enable_push", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_push_explainer, false)
     |> push_event("push:subscribe", %{})}
  end

  def handle_event("dismiss_push_explainer", _params, socket) do
    {:noreply, assign(socket, :show_push_explainer, false)}
  end
  ```

- [ ] **Step 3: Render the modal** in `chat_components.ex` (a sibling of `edit_profile_modal`). Mirror the existing modal triple-dismiss convention (backdrop + Escape + explicit X). Confirm button fires `confirm_enable_push`.

- [ ] **Step 4: Manual verification** — clicking "Enable Notifications" now opens the modal. Cancel = no browser prompt. Confirm = browser prompt appears.

- [ ] **Step 5: Commit**

### Task 4: Live health badge (kills the "Enabled" lie)

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex` — derive `:push_health` from existing assigns.
- Modify: `lib/slackex_web/components/chat_components.ex` — render badge next to the avatar in the sidebar header AND replace the "Enabled" badge in Edit Profile with the same component.
- Create: `test/slackex_web/live/chat_live/health_badge_test.exs`.

States and visual:
| State | Trigger | Visual |
|---|---|---|
| `:ok` | `push_permission == "granted" && push_subscribed && device tokens > 0 on server` | Small green check, "Notifications on" tooltip |
| `:browser_blocked` | `push_permission == "denied"` | Red bell-slash, "Browser blocked" tooltip + link to site settings |
| `:os_blocked` | inferred from "subscribed but no test push delivery in last 24h" — defer to v0.9.15, for v0.9.14 just treat as `:partial` | n/a |
| `:not_set_up` | `push_permission == "default"` OR no tokens | Amber bell with dot, "Set up notifications" — clicking it opens Edit Profile to the notification section |

For v0.9.14 we ship `:ok / :browser_blocked / :not_set_up` only. `:os_blocked` is a deeper change that needs delivery telemetry.

- [ ] **Step 1: Failing test** at `test/slackex_web/live/chat_live/health_badge_test.exs`:

  ```elixir
  defmodule SlackexWeb.ChatLive.HealthBadgeTest do
    use SlackexWeb.ConnCase, async: false
    import Phoenix.LiveViewTest
    import Slackex.TestFactory

    setup do
      Redix.command!(:redix_0, ["FLUSHDB"])
      FunWithFlags.enable(:push_notifications)
      on_exit(fn -> FunWithFlags.disable(:push_notifications) end)
      :ok
    end

    test "shows :not_set_up when permission is default", %{conn: conn} do
      user = insert(:user)
      conn = log_in_user(conn, user)
      {:ok, view, _} = live(conn, ~p"/chat")

      render_hook(view, "push:status", %{
        "permission" => "default",
        "subscribed" => false,
        "subscription" => nil
      })

      html = render(view)
      assert html =~ ~r{data-push-health="not_set_up"}
    end

    test "shows :browser_blocked when permission is denied", %{conn: conn} do
      user = insert(:user)
      conn = log_in_user(conn, user)
      {:ok, view, _} = live(conn, ~p"/chat")

      render_hook(view, "push:status", %{
        "permission" => "denied",
        "subscribed" => false,
        "subscription" => nil
      })

      assert render(view) =~ ~r{data-push-health="browser_blocked"}
    end

    test "shows :ok when permission granted, subscribed, and a token row exists", %{conn: conn} do
      user = insert(:user)
      sub = ~s({"endpoint":"https://fcm.googleapis.com/fcm/send/abc","keys":{"p256dh":"x","auth":"y"}})
      insert(:device_token, user: user, token: sub, platform: "web_push")

      conn = log_in_user(conn, user)
      {:ok, view, _} = live(conn, ~p"/chat")

      render_hook(view, "push:status", %{
        "permission" => "granted",
        "subscribed" => true,
        "subscription" => sub
      })

      assert render(view) =~ ~r{data-push-health="ok"}
    end
  end
  ```

- [ ] **Step 2: Run — expect failures.**

- [ ] **Step 3: Add `:push_health` derivation in `index.ex`.** Compute from the trio (`push_permission`, `push_subscribed`, server-side token count):

  ```elixir
  defp derive_push_health(socket) do
    has_token_row = device_token_exists?(socket.assigns.current_user.id)

    cond do
      socket.assigns.push_permission == "denied" -> :browser_blocked
      socket.assigns.push_subscribed and has_token_row -> :ok
      true -> :not_set_up
    end
  end

  defp device_token_exists?(user_id) do
    import Ecto.Query
    Slackex.Repo.exists?(from dt in Slackex.Notifications.DeviceToken, where: dt.user_id == ^user_id)
  end
  ```

  Re-derive whenever `push:status` fires (and on initial mount). Assign as `:push_health`.

- [ ] **Step 4: Render in `chat_components.ex`.** Sidebar header next to avatar:

  ```heex
  <button
    :if={@push_health != :ok}
    data-push-health={@push_health}
    phx-click="open_push_setup"
    class="btn btn-ghost btn-xs btn-square"
    title={push_health_tooltip(@push_health)}
  >
    <span class={push_health_icon(@push_health)} />
  </button>

  <span :if={@push_health == :ok} data-push-health="ok" class="hidden" />
  ```

  And add a private helper for the tooltip and icon classes (`hero-bell` amber for `:not_set_up`, `hero-bell-slash` red for `:browser_blocked`).

- [ ] **Step 5: Replace the "Enabled" badge** in Edit Profile (`chat_components.ex:910`) with a derived display sourced from `@push_health` so it can never lie again.

- [ ] **Step 6: Run — all 3 health badge tests pass + existing suite stays green.**

- [ ] **Step 7: Commit**

### Task 5: Verify + deploy

- [ ] **Step 1:** `mix test` — full suite green.
- [ ] **Step 2:** Manual cross-browser smoke: macOS PWA + Android PWA both reflect correct `push_health`. Click "Send test notification" → both devices get it. Click "Enable" with permission `default` → explainer modal shows.
- [ ] **Step 3:** `/deploy` to tag `v0.9.14`.

---

## Self-review notes

- `device_token_exists?` runs on every `push:status` and on mount. Cheap (indexed query, single boolean). If it shows up in a profile, cache it on the socket and only re-query when subscription changes.
- The pre-prompt modal is server-rendered (LiveView) rather than JS-only — that means the "Enable" button can't briefly show its old `requestPermission` behaviour during a slow socket. If we ever need to fire the modal without a server round-trip, we can promote it to a JS hook.
- `:os_blocked` detection requires push delivery telemetry we don't have yet. Deferred to v0.9.15.
- All Tier 1 work stays under the existing `:push_notifications` flag — no new flags introduced.

---

## Tier 2 / Tier 3 (deferred — not implemented in this plan)

See top of file for full descriptions. Each ships as a separate plan once Tier 1 has bedded in.
