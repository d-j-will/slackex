# WebSocket Resilience + Web Push Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the perceived "stale badge" problem in two complementary ways: (Phase 1) make the LiveView WebSocket recover quickly and surface catchup state when the app is open, and (Phase 2) extend the existing Web Push pipeline to update the OS app badge and any open clients when the app is backgrounded or suspended.

**Architecture:**
- Phase 1 is a LiveView/JS-only change: add a connection-state indicator, force reconnect on `visibilitychange`, and explicitly invoke `CatchupServer` on reconnect-mount so unread state is restored deterministically.
- Phase 2 extends the already-built VAPID push pipeline (`PushWorker` + service worker) with the W3C Badging API, a service-worker-to-client `postMessage` channel, and a client-side `pagevisibility` signal that the server uses to decide push eligibility instead of relying on the leaky `OnlineTracker` heartbeat.
- Cleanup of expired VAPID subscriptions (410/404) folded into Phase 2.

**Tech Stack:** Phoenix LiveView, Phoenix.PubSub, Oban, web-push (VAPID), W3C Badging API (`navigator.setAppBadge`), Service Worker `postMessage`, Page Visibility API.

**Sources verified during planning:**
- W3C Badging API: <https://w3c.github.io/badging/> — `navigator.setAppBadge(n)` / `clearAppBadge()`. iOS PWA support 16.4+. Feature-detect with `'setAppBadge' in navigator`.
- Service Worker `Client.postMessage`: <https://developer.mozilla.org/en-US/docs/Web/API/Client/postMessage>
- Phoenix LiveView reconnection: `phx-disconnected` / `phx-connected` selectors auto-toggle on socket state.

---

## File Map

**Create:**
- `assets/js/hooks/connection_status.js` — toggles a banner, forces reconnect on visibility/focus.
- `assets/js/hooks/app_badge.js` — wraps Badging API; clears badge on focus/visibility.
- `lib/slackex_web/live/chat_live/catchup.ex` — pure module that turns a `CatchupServer` payload into socket assigns + flash.
- `test/slackex_web/live/chat_live/catchup_test.exs`
- `test/slackex/notifications/push_eligibility_test.exs`
- `test/slackex/notifications/push_worker_dead_token_cleanup_test.exs`

**Modify:**
- `assets/js/app.js` — register the two new hooks, expose `liveSocket` reconnect helper.
- `lib/slackex_web/components/layouts/chat.html.heex` — connection-status banner element.
- `lib/slackex_web/live/chat_live/index.ex` — call catchup on reconnect-mount; track page visibility.
- `lib/slackex_web/live/chat_live/index.html.heex` — add `phx-hook="AppBadge"` and `phx-hook="ConnectionStatus"` mount points; bind unread total to badge.
- `priv/static/service-worker.js` — `setAppBadge` on push, `postMessage` to open clients, `clearAppBadge` on `notificationclick`.
- `lib/slackex/notifications/push_worker.ex` — push-eligibility decoupled from `OnlineTracker`; cleanup stale tokens on 410/404.
- `lib/slackex/notifications/web_push_adapter.ex` — surface 410/404 errors distinctly so the worker can act on them.

---

## Phase 1 — Foreground Resilience (Scenario B)

### Task 1: Surface connection state in the UI

**Files:**
- Create: `assets/js/hooks/connection_status.js`
- Modify: `assets/js/app.js` (register hook, ~line 30-50)
- Modify: `lib/slackex_web/components/layouts/chat.html.heex` (add banner)

- [ ] **Step 1: Write a Wallaby/Floki-free unit test for the hook is impractical — instead, add a manual verification step here.** Skip the JS unit test (no jsdom test infra); rely on the Phase 1 integration test in Task 4 + manual verification:

  Manual repro recipe (commit alongside the code as `docs/runbooks/manual-resilience-checks.md`):
  ```
  1. Open /chat in two browsers as different users.
  2. In browser A, open DevTools > Network > set throttling to "Offline".
  3. Within 5s the red "Reconnecting..." banner appears.
  4. Set throttling back to "No throttling". Banner clears within 2s.
  ```

- [ ] **Step 2: Add the hook**

  ```js
  // assets/js/hooks/connection_status.js
  const ConnectionStatus = {
    mounted() {
      this.banner = this.el;
      this.banner.classList.add("hidden");

      window.addEventListener("phx:page-loading-start", (e) => {
        if (e.detail.kind === "error") this._show();
      });
      window.addEventListener("phx:page-loading-stop", () => this._hide());

      // Force a reconnect when the tab regains focus or visibility — browsers
      // throttle background tabs and may have closed the socket while we slept.
      const forceReconnect = () => {
        if (document.visibilityState === "visible" && !window.liveSocket?.isConnected()) {
          window.liveSocket?.disconnect();
          window.liveSocket?.connect();
        }
      };
      document.addEventListener("visibilitychange", forceReconnect);
      window.addEventListener("focus", forceReconnect);
    },
    _show() { this.banner.classList.remove("hidden"); },
    _hide() { this.banner.classList.add("hidden"); },
  };

  export default ConnectionStatus;
  ```

- [ ] **Step 3: Register the hook**

  In `assets/js/app.js`, locate the `hooks: { ... }` object passed to `LiveSocket` and add:
  ```js
  import ConnectionStatus from "./hooks/connection_status";
  // …
  hooks: { /* existing hooks */, ConnectionStatus, /* ... */ },
  ```

- [ ] **Step 4: Add the banner to the chat layout**

  In `lib/slackex_web/components/layouts/chat.html.heex`, near the top of the chat container:
  ```heex
  <div
    id="connection-status"
    phx-hook="ConnectionStatus"
    phx-update="ignore"
    class="hidden fixed top-2 left-1/2 -translate-x-1/2 z-50 px-3 py-1 text-sm bg-warning text-warning-content rounded shadow"
  >
    Reconnecting…
  </div>
  ```

- [ ] **Step 5: Manual smoke test**

  ```
  mix phx.server
  # Open localhost:4000/chat, DevTools > Network > Offline. Banner appears.
  # Set Online. Banner disappears.
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add assets/js/hooks/connection_status.js assets/js/app.js \
          lib/slackex_web/components/layouts/chat.html.heex
  git commit -m "feat(presence): surface socket reconnect state and force reconnect on visibility"
  ```

### Task 2: Catchup module (pure)

**Files:**
- Create: `lib/slackex_web/live/chat_live/catchup.ex`
- Create: `test/slackex_web/live/chat_live/catchup_test.exs`

- [ ] **Step 1: Write the failing test**

  ```elixir
  # test/slackex_web/live/chat_live/catchup_test.exs
  defmodule SlackexWeb.ChatLive.CatchupTest do
    use Slackex.DataCase, async: true

    alias SlackexWeb.ChatLive.Catchup

    test "merges catchup unread counts into existing assigns" do
      existing = %{channel_counts: %{1 => 0}, dm_counts: %{}}
      catchup = %{
        channels: [%{channel_id: 1, unread_count: 3, channel_name: "general", channel_slug: "general", recent_messages: []}],
        timestamp: DateTime.utc_now()
      }

      merged = Catchup.merge_unread(existing, catchup)
      assert merged.channel_counts[1] == 3
    end

    test "produces a flash summary when there are missed messages" do
      catchup = %{
        channels: [
          %{channel_id: 1, unread_count: 3, channel_name: "general", channel_slug: "general", recent_messages: []},
          %{channel_id: 2, unread_count: 1, channel_name: "random", channel_slug: "random", recent_messages: []}
        ],
        timestamp: DateTime.utc_now()
      }

      assert Catchup.summary(catchup) == "4 new messages while you were away"
    end

    test "summary returns nil when nothing missed" do
      catchup = %{channels: [], timestamp: DateTime.utc_now()}
      assert Catchup.summary(catchup) == nil
    end
  end
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```
  mix test test/slackex_web/live/chat_live/catchup_test.exs
  ```
  Expected: 3 failures, "module SlackexWeb.ChatLive.Catchup is not loaded".

- [ ] **Step 3: Implement the module**

  ```elixir
  # lib/slackex_web/live/chat_live/catchup.ex
  defmodule SlackexWeb.ChatLive.Catchup do
    @moduledoc """
    Pure helpers that turn a `Slackex.Notifications.CatchupServer` payload
    into LiveView assign updates and a user-visible flash summary.
    """

    @type unread_counts :: %{channel_counts: %{integer() => non_neg_integer()}, dm_counts: %{integer() => non_neg_integer()}}

    @spec merge_unread(unread_counts(), map()) :: unread_counts()
    def merge_unread(existing, %{channels: channels}) do
      channel_counts =
        Enum.reduce(channels, existing.channel_counts, fn %{channel_id: id, unread_count: n}, acc ->
          Map.put(acc, id, n)
        end)

      %{existing | channel_counts: channel_counts}
    end

    @spec summary(map()) :: String.t() | nil
    def summary(%{channels: channels}) do
      total = Enum.reduce(channels, 0, &(&1.unread_count + &2))
      if total > 0, do: "#{total} new messages while you were away", else: nil
    end
  end
  ```

- [ ] **Step 4: Run test to verify it passes**

  ```
  mix test test/slackex_web/live/chat_live/catchup_test.exs
  ```
  Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

  ```bash
  git add lib/slackex_web/live/chat_live/catchup.ex test/slackex_web/live/chat_live/catchup_test.exs
  git commit -m "feat(catchup): pure module for merging CatchupServer payload into assigns"
  ```

### Task 3: Wire catchup into LiveView mount

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex` (mount/3, around line 40-72)

- [ ] **Step 1: Write a failing integration test**

  ```elixir
  # test/slackex_web/live/chat_live/index_catchup_test.exs
  defmodule SlackexWeb.ChatLive.IndexCatchupTest do
    use SlackexWeb.ConnCase
    import Phoenix.LiveViewTest
    import Slackex.TestFactory

    test "remount after missed messages restores unread counts and flashes summary", %{conn: conn} do
      user = insert(:user)
      other = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel)
      insert(:subscription, user: other, channel: channel)

      # Simulate messages that arrived while user was disconnected
      for n <- 1..3 do
        Slackex.Messaging.send_message(channel.id, other.id, "msg #{n}")
      end

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat")

      # Assert: the catchup flash appears
      assert render(view) =~ "3 new messages while you were away"

      # Assert: the channel sidebar shows unread badge of 3
      assert render(view) =~ ~r{##{channel.name}.*<span[^>]*>3</span>}s
    end
  end
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```
  mix test test/slackex_web/live/chat_live/index_catchup_test.exs
  ```
  Expected: FAIL — "3 new messages while you were away" not in render.

- [ ] **Step 3: Update mount to call catchup**

  In `lib/slackex_web/live/chat_live/index.ex`, change the `unread_counts = Chat.batch_unread_counts(user.id)` line (around line 55) to:

  ```elixir
  unread_counts = Chat.batch_unread_counts(user.id)

  {unread_counts, catchup_summary} =
    if connected?(socket) do
      catchup = Slackex.Notifications.CatchupServer.build_catchup(user.id)
      {SlackexWeb.ChatLive.Catchup.merge_unread(unread_counts, catchup),
       SlackexWeb.ChatLive.Catchup.summary(catchup)}
    else
      {unread_counts, nil}
    end
  ```

  And in the `socket |> assign(...)` chain, add at the bottom (just before the final `}`):
  ```elixir
  |> maybe_put_catchup_flash(catchup_summary)
  ```

  Add the helper at the bottom of the module's private helpers section:
  ```elixir
  defp maybe_put_catchup_flash(socket, nil), do: socket
  defp maybe_put_catchup_flash(socket, msg), do: Phoenix.LiveView.put_flash(socket, :info, msg)
  ```

- [ ] **Step 4: Run test to verify it passes**

  ```
  mix test test/slackex_web/live/chat_live/index_catchup_test.exs
  ```
  Expected: 1 test, 0 failures.

- [ ] **Step 5: Run the full chat_live test directory to catch regressions**

  ```
  mix test test/slackex_web/live/chat_live/
  ```
  Expected: 0 failures.

- [ ] **Step 6: Commit**

  ```bash
  git add lib/slackex_web/live/chat_live/index.ex test/slackex_web/live/chat_live/index_catchup_test.exs
  git commit -m "feat(catchup): apply CatchupServer payload on connected mount + flash summary"
  ```

### Task 4: Phase 1 end-to-end verification

- [ ] **Step 1: Run the full test suite**

  ```
  mix test
  ```
  Expected: 1437+ tests, 0 failures.

- [ ] **Step 2: Manual cross-browser smoke test**

  ```
  iex -S mix phx.server
  # Browser A: log in as user1, open /chat (root)
  # Browser B: log in as user2, post 3 messages in #general
  # Browser A: DevTools > Network > Offline > wait 30s
  # Set Online. Banner clears within 2s, "3 new messages while you were away" flash appears,
  # #general sidebar item shows badge of 3.
  ```

- [ ] **Step 3: Tag and deploy Phase 1**

  Use the `/deploy` skill. This is the natural cut-point — Phase 1 is independent and shippable.

---

## Phase 2 — Backgrounded PWA (Scenario A)

### Task 5: Service-worker badge + client postMessage

**Files:**
- Modify: `priv/static/service-worker.js`

- [ ] **Step 1: Add badge update + client broadcast**

  Replace the `push` handler (lines 29-44 in current file) with:

  ```js
  self.addEventListener('push', (event) => {
    const data = event.data?.json() || {};
    const options = {
      body: data.body || '',
      tag: data.tag || 'tenun-default',
      renotify: true,
      icon: '/images/icon-192.png',
      badge: '/images/icon-192.png',
      data: { url: data.url || '/chat', tag: data.tag },
    };

    event.waitUntil((async () => {
      // 1. Increment OS badge if supported (iOS 16.4+, desktop Chrome/Edge/Safari)
      if ('setAppBadge' in self.navigator) {
        try {
          // Persist count in IndexedDB-free state via a SW global; refreshed by clients.
          self._badgeCount = (self._badgeCount || 0) + 1;
          await self.navigator.setAppBadge(self._badgeCount);
        } catch (err) {
          console.warn('[SW] setAppBadge failed:', err);
        }
      }

      // 2. Tell any open clients so the in-app sidebar can increment immediately
      const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      const anyVisible = clients.some((c) => c.visibilityState === 'visible');

      for (const client of clients) {
        client.postMessage({ type: 'push:received', payload: data });
      }

      // 3. Suppress the OS notification if a client is visible — they got the postMessage.
      if (anyVisible) return;

      return self.registration.showNotification(data.title || 'Tenun', options);
    })());
  });
  ```

  Replace the `notificationclick` handler (lines 47-63) with:

  ```js
  self.addEventListener('notificationclick', (event) => {
    event.notification.close();

    event.waitUntil((async () => {
      // Clear OS badge — user is engaging
      if ('clearAppBadge' in self.navigator) {
        self._badgeCount = 0;
        try { await self.navigator.clearAppBadge(); } catch (_) {}
      }

      const windowClients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (const client of windowClients) {
        if (client.url.includes('/chat') && 'focus' in client) {
          client.navigate(event.notification.data.url);
          return client.focus();
        }
      }
      return self.clients.openWindow(event.notification.data.url);
    })());
  });
  ```

- [ ] **Step 2: Manual SW verification**

  ```
  # Open Chrome DevTools > Application > Service Workers > Push (input box):
  # paste {"title":"test","body":"hello","tag":"channel:1","url":"/chat/general"}
  # Verify: badge appears on the icon (PWA installed), notification suppressed if tab visible,
  # postMessage logged in the page console (we add the listener in Task 6).
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add priv/static/service-worker.js
  git commit -m "feat(push): SW updates app badge and notifies open clients"
  ```

### Task 6: Client app-badge hook

**Files:**
- Create: `assets/js/hooks/app_badge.js`
- Modify: `assets/js/app.js`
- Modify: `lib/slackex_web/live/chat_live/index.html.heex`

- [ ] **Step 1: Write the hook**

  ```js
  // assets/js/hooks/app_badge.js
  const AppBadge = {
    mounted() {
      // Listen for service-worker postMessages so we increment the in-app
      // sidebar even when the WebSocket missed the message.
      this._onSWMessage = (event) => {
        if (event.data?.type === "push:received") {
          this.pushEvent("push:received", event.data.payload || {});
        }
      };
      navigator.serviceWorker?.addEventListener("message", this._onSWMessage);

      // Clear OS badge whenever the user looks at the app
      const clear = () => {
        if (document.visibilityState === "visible" && "clearAppBadge" in navigator) {
          navigator.clearAppBadge().catch(() => {});
        }
      };
      document.addEventListener("visibilitychange", clear);
      window.addEventListener("focus", clear);
      clear();

      // Server can push an unread total to keep the OS badge in sync
      this.handleEvent("badge:set", ({ count }) => {
        if (!("setAppBadge" in navigator)) return;
        if (count > 0) navigator.setAppBadge(count).catch(() => {});
        else navigator.clearAppBadge().catch(() => {});
      });
    },
    destroyed() {
      navigator.serviceWorker?.removeEventListener("message", this._onSWMessage);
    },
  };

  export default AppBadge;
  ```

- [ ] **Step 2: Register the hook in `assets/js/app.js`**

  ```js
  import AppBadge from "./hooks/app_badge";
  // … in the hooks: { ... } object:
  AppBadge,
  ```

- [ ] **Step 3: Add a mount point in `lib/slackex_web/live/chat_live/index.html.heex`**

  Near the top of the chat container (sibling to the connection-status banner):
  ```heex
  <div id="app-badge" phx-hook="AppBadge" phx-update="ignore" class="hidden" />
  ```

- [ ] **Step 4: Push badge total from server on every unread change**

  In `lib/slackex_web/live/chat_live/helpers.ex`, modify `update_unread_count/4` to call:

  ```elixir
  def update_unread_count(socket, count_key, conversation_id, update_fn) do
    unread_counts = socket.assigns.unread_counts
    counts_map = Map.fetch!(unread_counts, count_key)
    current = Map.get(counts_map, conversation_id, 0)
    updated_counts = Map.put(counts_map, conversation_id, update_fn.(current))
    updated_unread = Map.put(unread_counts, count_key, updated_counts)

    total =
      (updated_unread.channel_counts |> Map.values() |> Enum.sum()) +
        (updated_unread.dm_counts |> Map.values() |> Enum.sum())

    socket
    |> assign(:unread_counts, updated_unread)
    |> Phoenix.LiveView.push_event("badge:set", %{count: total})
  end
  ```

  Also push `badge:set` once in mount after computing initial unread_counts.

- [ ] **Step 5: Manual verification**

  Background the PWA. Have another user post. Verify the OS badge appears with count 1 and that returning to the app clears it.

- [ ] **Step 6: Commit**

  ```bash
  git add assets/js/hooks/app_badge.js assets/js/app.js \
          lib/slackex_web/live/chat_live/index.html.heex \
          lib/slackex_web/live/chat_live/helpers.ex
  git commit -m "feat(push): client app-badge hook + server push_event for unread total"
  ```

### Task 7: Decouple push eligibility from OnlineTracker

**Background:** `PushWorker` currently checks `OnlineTracker.online?(user_id)` to decide whether to deliver. The TTL is 120s and the heartbeat is 60s, so a user can be marked online for up to two minutes after their socket actually died. During that window NO push is sent, and the user's PWA shows a stale badge. Fix: track a separate "active" signal that the LiveView refreshes only while the page is visible.

**Files:**
- Create: `lib/slackex/notifications/active_tracker.ex` — Redis key `active:{user_id}` with **20s** TTL.
- Modify: `lib/slackex/notifications/push_worker.ex` (use `ActiveTracker` instead of `OnlineTracker`).
- Modify: `lib/slackex_web/live/chat_live/index.ex` — refresh ActiveTracker on visibility change.
- Create: `test/slackex/notifications/push_eligibility_test.exs`

- [ ] **Step 1: Write the failing test**

  ```elixir
  # test/slackex/notifications/push_eligibility_test.exs
  defmodule Slackex.Notifications.PushEligibilityTest do
    use Slackex.DataCase, async: false

    alias Slackex.Notifications.{ActiveTracker, PushWorker}
    import Slackex.TestFactory

    setup do
      FunWithFlags.enable(:push_notifications)
      on_exit(fn -> FunWithFlags.disable(:push_notifications) end)
      :ok
    end

    test "user with stale OnlineTracker but no ActiveTracker still receives push" do
      user = insert(:user)
      sender = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel)
      insert(:device_token, user: user, token: "test-token", platform: "web")

      # User is "online" per heartbeat but their tab is backgrounded — no active marker
      Slackex.Notifications.OnlineTracker.mark_online(user.id)
      ActiveTracker.mark_inactive(user.id)

      job = %Oban.Job{
        args: %{
          "type" => "new_message",
          "channel_id" => channel.id,
          "sender_id" => sender.id,
          "content" => "hi",
          "sender_username" => sender.username
        }
      }

      assert :ok = PushWorker.perform(job)
      assert_received {:stub_push_sent, "test-token", _payload}
    end
  end
  ```

  This requires `Slackex.Notifications.PushAdapter.Stub` to send a `:stub_push_sent` message to `self()` when invoked. If it doesn't already, add that behavior.

- [ ] **Step 2: Run test to verify it fails**

  ```
  mix test test/slackex/notifications/push_eligibility_test.exs
  ```
  Expected: FAIL — `ActiveTracker` not defined.

- [ ] **Step 3: Implement ActiveTracker**

  ```elixir
  # lib/slackex/notifications/active_tracker.ex
  defmodule Slackex.Notifications.ActiveTracker do
    @moduledoc """
    Tracks whether a user is *actively engaged* (tab visible, focused) — distinct
    from `OnlineTracker` which only knows the LiveView heartbeat is alive.

    Key: `active:{user_id}`. TTL 20s. Refreshed by client-driven heartbeats.
    """

    @ttl_seconds 20

    defp redis_key(user_id), do: "active:#{user_id}"
    defp random_conn, do: :"redix_#{:rand.uniform(10) - 1}"

    def mark_active(user_id) do
      _ = Redix.command(random_conn(), ["SET", redis_key(user_id), "1", "EX", @ttl_seconds])
      :ok
    end

    def mark_inactive(user_id) do
      _ = Redix.command(random_conn(), ["DEL", redis_key(user_id)])
      :ok
    end

    def active?(user_id) do
      case Redix.command(random_conn(), ["GET", redis_key(user_id)]) do
        {:ok, val} when not is_nil(val) -> true
        _ -> false
      end
    end
  end
  ```

- [ ] **Step 4: Switch PushWorker over**

  In `lib/slackex/notifications/push_worker.ex`:
  - Replace `alias Slackex.Notifications.{... OnlineTracker ...}` to drop `OnlineTracker` and add `ActiveTracker`.
  - Replace `Enum.reject(&OnlineTracker.online?(&1.user_id))` with `Enum.reject(&ActiveTracker.active?(&1.user_id))`.
  - Replace `if OnlineTracker.online?(recipient_id)` with `if ActiveTracker.active?(recipient_id)`.

- [ ] **Step 5: Refresh ActiveTracker from the LiveView**

  In `lib/slackex_web/live/chat_live/index.ex`:
  - After `OnlineTracker.mark_online(user.id)` in mount, also call `ActiveTracker.mark_active(user.id)`.
  - Schedule an `:active_heartbeat` every 10s while the page is visible.
  - Add `handle_event("page:hidden", ...)` that calls `ActiveTracker.mark_inactive(user.id)`.
  - Add `handle_event("page:visible", ...)` that calls `ActiveTracker.mark_active(user.id)`.

  In `assets/js/hooks/app_badge.js`, add to the `mounted()` hook:
  ```js
  document.addEventListener("visibilitychange", () => {
    this.pushEvent(document.visibilityState === "visible" ? "page:visible" : "page:hidden", {});
  });
  ```

- [ ] **Step 6: Run test to verify it passes**

  ```
  mix test test/slackex/notifications/push_eligibility_test.exs
  ```
  Expected: 1 test, 0 failures.

- [ ] **Step 7: Run the broader notifications test suite**

  ```
  mix test test/slackex/notifications/
  ```
  Expected: 0 failures.

- [ ] **Step 8: Commit**

  ```bash
  git add lib/slackex/notifications/active_tracker.ex lib/slackex/notifications/push_worker.ex \
          lib/slackex_web/live/chat_live/index.ex assets/js/hooks/app_badge.js \
          test/slackex/notifications/push_eligibility_test.exs
  git commit -m "feat(push): decouple push eligibility from OnlineTracker via ActiveTracker"
  ```

### Task 8: Stale subscription cleanup

**Background:** When a VAPID subscription expires (browser uninstalled / permission revoked / push service rotates), the push service returns HTTP 410 (Gone) or 404. Today the PushWorker logs and retries until max_attempts; the dead token sticks around forever and counts against future delivery throughput.

**Files:**
- Modify: `lib/slackex/notifications/web_push_adapter.ex` — return `{:error, :gone}` on 410/404.
- Modify: `lib/slackex/notifications/push_worker.ex` — on `{:error, :gone}`, delete the device token row, do NOT retry.
- Create: `test/slackex/notifications/push_worker_dead_token_cleanup_test.exs`

- [ ] **Step 1: Write the failing test**

  ```elixir
  # test/slackex/notifications/push_worker_dead_token_cleanup_test.exs
  defmodule Slackex.Notifications.PushWorkerDeadTokenCleanupTest do
    use Slackex.DataCase, async: false
    alias Slackex.Notifications.{DeviceToken, PushWorker}
    alias Slackex.Repo

    setup do
      FunWithFlags.enable(:push_notifications)
      original = Application.get_env(:slackex, :push_adapter)
      Application.put_env(:slackex, :push_adapter, GoneAdapterStub)

      on_exit(fn ->
        Application.put_env(:slackex, :push_adapter, original)
        FunWithFlags.disable(:push_notifications)
      end)
    end

    defmodule GoneAdapterStub do
      def send_push(_token, _platform, _payload), do: {:error, :gone}
    end

    test "410/Gone push deletes the device token row" do
      user = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel)
      token = insert(:device_token, user: user, token: "dead-token", platform: "web")

      sender = insert(:user)

      job = %Oban.Job{args: %{
        "type" => "new_message", "channel_id" => channel.id, "sender_id" => sender.id,
        "content" => "x", "sender_username" => sender.username
      }}

      _ = PushWorker.perform(job)

      refute Repo.get(DeviceToken, token.id)
    end
  end
  ```

- [ ] **Step 2: Run to verify it fails**

  ```
  mix test test/slackex/notifications/push_worker_dead_token_cleanup_test.exs
  ```

- [ ] **Step 3: Update the adapter to surface :gone**

  In `lib/slackex/notifications/web_push_adapter.ex`, in the response-handling clause(s):
  ```elixir
  case status do
    s when s in [404, 410] -> {:error, :gone}
    s when s in 200..299 -> :ok
    _ -> {:error, {:http, status}}
  end
  ```

- [ ] **Step 4: Update PushWorker to delete on :gone**

  In `dispatch_push/4`, change:
  ```elixir
  adapter.send_push(token, platform, payload)
  ```
  to:
  ```elixir
  case adapter.send_push(token, platform, payload) do
    {:error, :gone} ->
      _ = Repo.delete_all(from dt in DeviceToken, where: dt.token == ^token)
      :ok
    other ->
      other
  end
  ```

- [ ] **Step 5: Run test to verify it passes**

  ```
  mix test test/slackex/notifications/push_worker_dead_token_cleanup_test.exs
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add lib/slackex/notifications/web_push_adapter.ex \
          lib/slackex/notifications/push_worker.ex \
          test/slackex/notifications/push_worker_dead_token_cleanup_test.exs
  git commit -m "feat(push): delete device tokens that return 410/404 instead of retrying"
  ```

### Task 9: Phase 2 end-to-end verification + deploy

- [ ] **Step 1: Full test suite**

  ```
  mix test
  ```
  Expected: 1437+ tests, 0 failures.

- [ ] **Step 2: Manual installed-PWA test**

  ```
  Install Tenun as PWA on macOS Chrome and iOS Safari (16.4+).
  Background the PWA. From a second account, post in a subscribed channel.
  Within ~3s of the message: OS badge appears with count.
  Foreground the PWA: badge clears, sidebar shows the unread count.
  Open the message: notification dismisses, sidebar count decrements.
  ```

- [ ] **Step 3: Tag and deploy via `/deploy` skill**

---

## Self-Review Notes

- **Spec coverage:** Phase 1 covers scenario B (foreground reconnect + catchup). Phase 2 covers scenario A (backgrounded badge + push reliability). Cleanup of stale tokens is folded in as Task 8 because it's a precondition for any sustained push delivery.
- **Open assumption:** Task 5 stores `_badgeCount` on the SW global. Service workers can be terminated and restarted at any time; if that happens between pushes the count resets. Acceptable v1 — server-side push of authoritative count via `badge:set` (Task 6) corrects it as soon as a client connects. If we later see complaints, persist `_badgeCount` to IndexedDB.
- **Out of scope:** push delivery from non-message events (mentions in threads, reactions on your messages, channel invites). Adding these is a follow-up — the eligibility/cleanup machinery built here applies unchanged.
- **Risk:** Task 7 changes who receives push. After deploy, watch the Oban `notifications` queue and the Grafana push-delivery metrics for a 24h window. Roll back via the existing `:push_notifications` feature flag if delivery rate spikes unexpectedly.
