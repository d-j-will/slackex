defmodule SlackexWeb.API.BootstrapControllerTest do
  use SlackexWeb.ConnCase, async: true

  import Slackex.Factory

  alias Slackex.Accounts.Auth
  alias Slackex.Chat

  setup %{conn: conn} do
    user = insert(:user)
    token = Auth.generate_api_token(user)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    %{conn: conn, user: user}
  end

  describe "GET /api/bootstrap" do
    test "authenticated user gets user data, channels, dms, and unread counts", %{
      conn: conn,
      user: user
    } do
      {:ok, _channel} =
        Chat.create_channel(user.id, %{name: "bootstrap-channel", description: "Test"})

      conn = get(conn, ~p"/api/bootstrap")

      assert %{
               "user" => serialized_user,
               "channels" => channels,
               "dms" => dms,
               "unread_counts" => unread_counts
             } = json_response(conn, 200)

      assert serialized_user["username"] == user.username
      assert is_list(channels)
      assert is_list(dms)
      assert is_map(unread_counts)
    end

    test "unauthenticated request returns 401" do
      conn = build_conn()
      conn = get(conn, ~p"/api/bootstrap")
      assert %{"error" => _} = json_response(conn, 401)
    end

    test "response includes correct user data", %{conn: conn, user: user} do
      conn = get(conn, ~p"/api/bootstrap")
      assert %{"user" => serialized_user} = json_response(conn, 200)
      assert serialized_user["id"] == to_string(user.id)
      assert serialized_user["username"] == user.username
      refute Map.has_key?(serialized_user, "hashed_password")
      refute Map.has_key?(serialized_user, "email")
    end

    test "includes channels the user has joined", %{conn: conn, user: user} do
      {:ok, ch1} = Chat.create_channel(user.id, %{name: "channel-one", description: "One"})
      {:ok, ch2} = Chat.create_channel(user.id, %{name: "channel-two", description: "Two"})

      conn = get(conn, ~p"/api/bootstrap")
      assert %{"channels" => channels} = json_response(conn, 200)

      channel_ids = Enum.map(channels, & &1["id"])
      assert to_string(ch1.id) in channel_ids
      assert to_string(ch2.id) in channel_ids
    end

    test "includes DM conversations the user is part of", %{conn: conn, user: user} do
      other = insert(:user)
      {:ok, dm} = Chat.find_or_create_dm(user.id, other.id)

      conn = get(conn, ~p"/api/bootstrap")
      assert %{"dms" => dms} = json_response(conn, 200)

      dm_ids = Enum.map(dms, & &1["id"])
      assert to_string(dm.id) in dm_ids
    end

    test "unread counts are keyed by channel id string", %{conn: conn, user: user} do
      {:ok, channel} = Chat.create_channel(user.id, %{name: "counted-channel", description: "C"})

      conn = get(conn, ~p"/api/bootstrap")
      assert %{"unread_counts" => unread_counts} = json_response(conn, 200)

      assert Map.has_key?(unread_counts, to_string(channel.id))
    end
  end
end
