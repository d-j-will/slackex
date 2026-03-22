defmodule SlackexWeb.MCP.SubscriberTest do
  use Slackex.DataCase, async: false

  alias SlackexWeb.MCP.Subscriber
  alias Slackex.Messaging.Envelope

  describe "event filtering" do
    test "forwards matching events, drops non-matching" do
      {:ok, pid} =
        Subscriber.start_link(%{
          session_pid: self(),
          channel_id: 123,
          event_types: ["new_message", "message_deleted"]
        })

      # Use REAL envelope shape
      envelope = Envelope.wrap("message.new", {:channel, 123}, %{id: 1, content: "test"})
      send(pid, {:envelope, envelope})
      assert_receive {:mcp_event, %{type: "new_message", payload: _}}, 1000

      # typing is not in event_types — should be dropped
      typing_envelope = Envelope.wrap("typing", {:channel, 123}, %{user_id: 1, username: "alice"})
      send(pid, {:envelope, typing_envelope})
      refute_receive {:mcp_event, %{type: "typing"}}, 200

      GenServer.stop(pid)
    end

    test "uses default event types when none specified" do
      {:ok, pid} =
        Subscriber.start_link(%{
          session_pid: self(),
          channel_id: 456,
          event_types: nil
        })

      envelope = Envelope.wrap("message.new", {:channel, 456}, %{id: 1, content: "hi"})
      send(pid, {:envelope, envelope})
      assert_receive {:mcp_event, _}, 1000

      GenServer.stop(pid)
    end

    test "maps PubSub event names to MCP event types" do
      {:ok, pid} =
        Subscriber.start_link(%{
          session_pid: self(),
          channel_id: 789,
          event_types: ["message_edited", "reaction_toggled"]
        })

      # message.edited → message_edited
      envelope =
        Envelope.wrap("message.edited", {:channel, 789}, %{
          id: 1,
          content: "updated",
          edited_at: DateTime.utc_now()
        })

      send(pid, {:envelope, envelope})
      assert_receive {:mcp_event, %{type: "message_edited"}}, 1000

      # reaction.toggled → reaction_toggled
      reaction_env =
        Envelope.wrap("reaction.toggled", {:channel, 789}, %{
          message_id: 1,
          emoji: "heart",
          user_id: 2,
          action: :added
        })

      send(pid, {:envelope, reaction_env})
      assert_receive {:mcp_event, %{type: "reaction_toggled"}}, 1000

      GenServer.stop(pid)
    end

    test "includes timestamp from envelope meta" do
      {:ok, pid} =
        Subscriber.start_link(%{
          session_pid: self(),
          channel_id: 100,
          event_types: ["new_message"]
        })

      envelope = Envelope.wrap("message.new", {:channel, 100}, %{id: 1, content: "ts test"})
      send(pid, {:envelope, envelope})
      assert_receive {:mcp_event, %{type: "new_message", timestamp: ts}}, 1000
      assert %DateTime{} = ts

      GenServer.stop(pid)
    end
  end
end
