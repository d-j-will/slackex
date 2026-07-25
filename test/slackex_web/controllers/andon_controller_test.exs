defmodule SlackexWeb.AndonControllerTest do
  @moduledoc """
  System-boundary tests for the relay's inbound push endpoint
  (`POST /api/andon/commands`): bearer auth, the flag gate, and the two
  outbound commands (`update_mirror` create-then-edit + watermark staleness;
  `notify_backup` in-thread). async: false — commands spawn ChannelServer
  processes that need shared sandbox access.
  """
  use SlackexWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Slackex.Andon
  alias Slackex.Chat

  @token "test-relay-token"

  setup do
    user = insert(:user)
    channel = insert(:channel, creator: user, is_private: false)
    {:ok, _row} = Andon.enable_channel(channel.id)
    # Sandbox rollback clears the flag row; no DB work in on_exit (house rule).
    FunWithFlags.enable(:andon_relay)

    %{conn: build_conn(), user: user, channel: channel}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp hold(external_id, thread) do
    %{
      "class" => "defect",
      "thread" => thread,
      "subject" => %{"external_id" => external_id},
      "held_since" => DateTime.to_iso8601(DateTime.utc_now()),
      "escalated" => false
    }
  end

  defp mirror_command(channel_id, watermark, mirror) do
    %{
      "command" => "update_mirror",
      "relay" => "slackex",
      "channel" => to_string(channel_id),
      "watermark" => watermark,
      "mirror" => mirror
    }
  end

  describe "authentication (fail-closed bearer)" do
    test "no authorization header → 401", %{conn: conn, channel: channel} do
      conn =
        post(conn, ~p"/api/andon/commands", mirror_command(channel.id, 1, %{}))

      assert json_response(conn, 401)
      assert Andon.get_channel(channel.id).status_message_id == nil
    end

    test "wrong bearer token → 401", %{conn: conn, channel: channel} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer nope")
        |> post(~p"/api/andon/commands", mirror_command(channel.id, 1, %{}))

      assert json_response(conn, 401)
    end
  end

  describe "feature flag gate (dark-ship inert)" do
    test "with :andon_relay off the endpoint is 404 even with a valid token", %{
      conn: conn,
      channel: channel
    } do
      FunWithFlags.disable(:andon_relay)

      conn = post(authed(conn), ~p"/api/andon/commands", mirror_command(channel.id, 1, %{}))

      assert json_response(conn, 404)
    end
  end

  describe "update_mirror: one message per channel, created once then edited" do
    test "first update creates the status message; a higher watermark edits it in place", %{
      conn: conn,
      channel: channel
    } do
      first =
        mirror_command(channel.id, 1, %{
          "active_holds" => [hold("ENG-123", "T-1")],
          "unbound_pulls" => [],
          "oldest_open" => nil
        })

      assert %{"ok" => true} =
               json_response(post(authed(conn), ~p"/api/andon/commands", first), 200)

      row = Andon.get_channel(channel.id)
      assert row.last_watermark == 1
      assert is_integer(row.status_message_id)
      message_id = row.status_message_id
      assert {:ok, message} = Chat.get_message(message_id)
      assert message.content =~ "ENG-123"

      # Person-blind: the rendered mirror carries no user tokens.
      refute message.content =~ "token"

      second =
        mirror_command(channel.id, 2, %{
          "active_holds" => [],
          "unbound_pulls" => [
            %{
              "class" => "defect",
              "thread" => "T-2",
              "since" => DateTime.to_iso8601(DateTime.utc_now())
            }
          ],
          "oldest_open" => nil
        })

      assert %{"ok" => true} =
               json_response(post(authed(build_conn()), ~p"/api/andon/commands", second), 200)

      row = Andon.get_channel(channel.id)
      assert row.last_watermark == 2
      # Edited in place: same message id, new content.
      assert row.status_message_id == message_id
      assert {:ok, edited} = Chat.get_message(message_id)
      assert edited.content =~ "awaiting a subject"
      refute edited.content =~ "ENG-123"
    end

    test "a stale (lower-or-equal) watermark is dropped", %{conn: conn, channel: channel} do
      current =
        mirror_command(channel.id, 5, %{
          "active_holds" => [hold("ENG-999", "T-9")],
          "unbound_pulls" => [],
          "oldest_open" => nil
        })

      post(authed(conn), ~p"/api/andon/commands", current)
      row = Andon.get_channel(channel.id)
      assert row.last_watermark == 5
      message_id = row.status_message_id

      stale =
        mirror_command(channel.id, 3, %{
          "active_holds" => [hold("ENG-000", "T-0")],
          "unbound_pulls" => [],
          "oldest_open" => nil
        })

      post(authed(build_conn()), ~p"/api/andon/commands", stale)

      row = Andon.get_channel(channel.id)
      assert row.last_watermark == 5
      assert row.status_message_id == message_id
      assert {:ok, message} = Chat.get_message(message_id)
      assert message.content =~ "ENG-999"
      refute message.content =~ "ENG-000"
    end
  end

  describe "notify_backup: an in-thread reply mentioning the backup" do
    test "posts a reply in the pull's thread mentioning the backup user", %{
      conn: conn,
      channel: channel,
      user: puller
    } do
      backup_user = insert(:user, username: "backup-dri")
      root = insert(:message, channel: channel, sender: puller)

      command = %{
        "command" => "notify_backup",
        "backup" => %{"relay" => "slackex", "token" => to_string(backup_user.id)},
        "thread" => to_string(root.id)
      }

      assert %{"ok" => true} =
               json_response(post(authed(conn), ~p"/api/andon/commands", command), 200)

      assert [reply] = Chat.list_thread(root.id)
      assert reply.content =~ "@backup-dri"
      assert reply.content =~ "acknowledge window"
      # The backup is now the DRI, so their notice teaches the DRI affordances.
      assert reply.content =~ "`ack`"
      assert reply.content =~ "`note:"
    end

    test "uses the command's explicit channel and lands the reply there", %{
      conn: conn,
      channel: channel,
      user: puller
    } do
      backup_user = insert(:user, username: "backup-two")
      root = insert(:message, channel: channel, sender: puller)

      # The channel now rides the payload (service fix), so resolution reads it
      # directly instead of looking the thread message up. The reply still
      # threads under the real parent message id.
      command = %{
        "command" => "notify_backup",
        "backup" => %{"relay" => "slackex", "token" => to_string(backup_user.id)},
        "channel" => to_string(channel.id),
        "thread" => to_string(root.id)
      }

      assert %{"ok" => true} =
               json_response(post(authed(conn), ~p"/api/andon/commands", command), 200)

      assert [reply] = Chat.list_thread(root.id)
      assert reply.content =~ "@backup-two"
      assert reply.channel_id == channel.id
    end

    test "an unresolvable channel logs a warning instead of dropping silently", %{conn: conn} do
      command = %{
        "command" => "notify_backup",
        "backup" => %{"relay" => "slackex", "token" => "U-x"},
        # No channel field, and a thread that resolves to no message.
        "thread" => "T-unresolvable"
      }

      log =
        capture_log(fn ->
          assert %{"ok" => true} =
                   json_response(post(authed(conn), ~p"/api/andon/commands", command), 200)
        end)

      assert log =~ "dropped notify_backup"
    end
  end

  describe "notify_dri: an in-thread reply telling the DRI they're on the clock" do
    test "posts a reply in the pull's thread mentioning the DRI user", %{
      conn: conn,
      channel: channel,
      user: puller
    } do
      dri_user = insert(:user, username: "stage-dri")
      root = insert(:message, channel: channel, sender: puller)

      command = %{
        "command" => "notify_dri",
        "dri" => %{"relay" => "slackex", "token" => to_string(dri_user.id)},
        "channel" => to_string(channel.id),
        "thread" => to_string(root.id),
        "subject" => %{"adapter" => "linear", "external_id" => "ENG-42"},
        "class" => "defect",
        "stage" => "build",
        "ack_due_at" => "2026-07-25T15:20:00Z"
      }

      assert %{"ok" => true} =
               json_response(post(authed(conn), ~p"/api/andon/commands", command), 200)

      assert [reply] = Chat.list_thread(root.id)
      assert reply.content =~ "@stage-dri"

      # The receipt states everything needed to decide whether to move: what
      # it is about, where it sits, and when it is owed. The deadline is a
      # time, not a countdown — a countdown in a chat message is stale the
      # moment it is written.
      assert reply.content =~ "ENG-42"
      assert reply.content =~ "defect"
      assert reply.content =~ "build"
      assert reply.content =~ "15:20"

      # Teaches the DRI's affordances in-thread (ENG-13 gap 2).
      # resolved/withdraw are the puller's — taught in the puller confirmation.
      assert reply.content =~ "`heard`"
      assert reply.content =~ "`ack`"
      assert reply.content =~ "`note:"
      assert reply.content =~ "cause:"
      refute reply.content =~ "resolved"
      refute reply.content =~ "withdraw"
      assert reply.channel_id == channel.id
    end

    test "a class with no clock says so rather than implying a timer", %{
      conn: conn,
      channel: channel,
      user: puller
    } do
      dri_user = insert(:user, username: "stage-dri-2")
      root = insert(:message, channel: channel, sender: puller)

      command = %{
        "command" => "notify_dri",
        "dri" => %{"relay" => "slackex", "token" => to_string(dri_user.id)},
        "channel" => to_string(channel.id),
        "thread" => to_string(root.id),
        "subject" => %{"adapter" => "linear", "external_id" => "ENG-43"},
        "class" => "confusion",
        "stage" => "build",
        "ack_due_at" => nil
      }

      assert %{"ok" => true} =
               json_response(post(authed(conn), ~p"/api/andon/commands", command), 200)

      assert [reply] = Chat.list_thread(root.id)
      assert reply.content =~ "No clock on this one"
    end

    test "an unresolvable channel logs a warning instead of dropping silently", %{conn: conn} do
      command = %{
        "command" => "notify_dri",
        "dri" => %{"relay" => "slackex", "token" => "U-x"},
        # No channel field, and a thread that resolves to no message.
        "thread" => "T-unresolvable"
      }

      log =
        capture_log(fn ->
          assert %{"ok" => true} =
                   json_response(post(authed(conn), ~p"/api/andon/commands", command), 200)
        end)

      assert log =~ "dropped notify_dri"
    end
  end
end
