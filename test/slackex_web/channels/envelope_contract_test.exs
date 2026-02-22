defmodule SlackexWeb.Channels.EnvelopeContractTest do
  @moduledoc """
  Contract tests for the versioned envelope protocol.

  These tests verify that the realtime channel protocol maintains its shape
  guarantees for client consumers. Tagged `:contract` — excluded from the
  default test run; use `mix test --include contract` to run them explicitly.
  """

  use SlackexWeb.ChannelCase, async: false

  alias Slackex.Accounts.Auth
  alias Slackex.Chat
  alias Slackex.Messaging

  # ---------------------------------------------------------------------------
  # ChatChannel — Write Rejection Contract
  # ---------------------------------------------------------------------------

  describe "ChatChannel write rejection contract" do
    @describetag :contract

    setup do
      user = insert(:user)
      token = Auth.generate_api_token(user)
      {:ok, socket} = connect(SlackexWeb.UserSocket, %{"token" => token})

      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "contract-#{System.unique_integer()}"})

      {:ok, _reply, socket} = subscribe_and_join(socket, "chat:#{channel.id}", %{})
      %{socket: socket, user: user, channel: channel}
    end

    test "rate_limited error has normalized shape", %{socket: socket} do
      for _ <- 1..10, do: push(socket, "new_message", %{"content" => "burst"})
      ref = push(socket, "new_message", %{"content" => "11th"})
      assert_reply ref, :error, %{reason: "rate_limited", message: _}
    end

    test "invalid_content error for empty content", %{socket: socket} do
      ref = push(socket, "new_message", %{"content" => ""})
      assert_reply ref, :error, %{reason: "invalid_content", message: _}
    end

    test "invalid_content error for content exceeding 4000 chars", %{socket: socket} do
      ref = push(socket, "new_message", %{"content" => String.duplicate("a", 4_001)})
      assert_reply ref, :error, %{reason: "invalid_content", message: _}
    end

    test "unauthorized error for viewer-role user", %{channel: channel} do
      viewer = insert(:user)
      insert(:subscription, %{user: viewer, channel: channel, role: "viewer"})
      viewer_token = Auth.generate_api_token(viewer)
      {:ok, viewer_socket} = connect(SlackexWeb.UserSocket, %{"token" => viewer_token})

      {:ok, _reply, viewer_socket} =
        subscribe_and_join(viewer_socket, "chat:#{channel.id}", %{})

      ref = push(viewer_socket, "new_message", %{"content" => "unauthorized attempt"})
      assert_reply ref, :error, %{reason: "unauthorized", message: _}
    end
  end

  # ---------------------------------------------------------------------------
  # ChatChannel — Envelope Contract
  # ---------------------------------------------------------------------------

  describe "ChatChannel envelope contract" do
    @describetag :contract

    setup do
      user = insert(:user)
      token = Auth.generate_api_token(user)
      {:ok, socket} = connect(SlackexWeb.UserSocket, %{"token" => token})

      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "contract-#{System.unique_integer()}"})

      {:ok, _reply, socket} = subscribe_and_join(socket, "chat:#{channel.id}", %{})
      %{socket: socket, user: user, channel: channel}
    end

    test "new messages are pushed as message.new event", %{socket: socket, user: user} do
      ref = push(socket, "new_message", %{"content" => "envelope test"})
      assert_reply ref, :ok
      assert_push "message.new", %{id: id, content: "envelope test", sender_id: sender_id}
      assert is_binary(id)
      assert sender_id == to_string(user.id)
    end

    test "message payload inserted_at is a DateTime", %{socket: socket} do
      ref = push(socket, "new_message", %{"content" => "ts test"})
      assert_reply ref, :ok
      assert_push "message.new", %{inserted_at: inserted_at}
      assert %DateTime{} = inserted_at
    end

    test "typing events are pushed as typing event", %{channel: channel, user: user} do
      Messaging.broadcast_typing(channel.id, user)
      assert_push "typing", %{user_id: _, username: _}
    end
  end

  # ---------------------------------------------------------------------------
  # DMChannel — Write Rejection Contract
  # ---------------------------------------------------------------------------

  describe "DMChannel write rejection contract" do
    @describetag :contract

    setup do
      alice = insert(:user)
      bob = insert(:user)
      alice_token = Auth.generate_api_token(alice)
      {:ok, socket} = connect(SlackexWeb.UserSocket, %{"token" => alice_token})
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)
      {:ok, _reply, socket} = subscribe_and_join(socket, "dm:#{dm.id}", %{})
      %{socket: socket, alice: alice, dm: dm}
    end

    test "rate_limited error has normalized shape", %{socket: socket} do
      for _ <- 1..10, do: push(socket, "new_message", %{"content" => "burst"})
      ref = push(socket, "new_message", %{"content" => "11th"})
      assert_reply ref, :error, %{reason: "rate_limited", message: _}
    end

    test "invalid_content error for empty content", %{socket: socket} do
      ref = push(socket, "new_message", %{"content" => ""})
      assert_reply ref, :error, %{reason: "invalid_content", message: _}
    end

    test "invalid_content error for content exceeding 4000 chars", %{socket: socket} do
      ref = push(socket, "new_message", %{"content" => String.duplicate("a", 4_001)})
      assert_reply ref, :error, %{reason: "invalid_content", message: _}
    end
  end

  # ---------------------------------------------------------------------------
  # DMChannel — Envelope Contract
  # ---------------------------------------------------------------------------

  describe "DMChannel envelope contract" do
    @describetag :contract

    setup do
      alice = insert(:user)
      bob = insert(:user)
      alice_token = Auth.generate_api_token(alice)
      {:ok, socket} = connect(SlackexWeb.UserSocket, %{"token" => alice_token})
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)
      {:ok, _reply, socket} = subscribe_and_join(socket, "dm:#{dm.id}", %{})
      %{socket: socket, alice: alice}
    end

    test "new DM messages are pushed as message.new event", %{socket: socket, alice: alice} do
      ref = push(socket, "new_message", %{"content" => "direct envelope test"})
      assert_reply ref, :ok
      assert_push "message.new", %{id: id, content: "direct envelope test", sender_id: sender_id}
      assert is_binary(id)
      assert sender_id == to_string(alice.id)
    end

    test "message payload inserted_at is a DateTime", %{socket: socket} do
      ref = push(socket, "new_message", %{"content" => "dm ts test"})
      assert_reply ref, :ok
      assert_push "message.new", %{inserted_at: inserted_at}
      assert %DateTime{} = inserted_at
    end
  end
end
