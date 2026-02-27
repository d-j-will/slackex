defmodule Slackex.Factory do
  @moduledoc false

  use ExMachina.Ecto, repo: Slackex.Repo

  alias Slackex.Accounts.User
  alias Slackex.Chat.{Channel, DMConversation, DMRequest, Message, ReadCursor, Subscription}
  alias Slackex.Notifications.DeviceToken

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
    name = sequence(:channel_name, &"channel-#{&1}")

    %Channel{
      name: name,
      slug: name,
      description: "A test channel",
      is_private: false,
      creator: build(:user)
    }
  end

  def private_channel_factory do
    struct!(channel_factory(), is_private: true)
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
    # Use a large monotonic integer as a valid bigint ID (not a real Snowflake,
    # but valid for factory use where Snowflake GenServer is not started)
    id = 1_000_000_000_000 + System.unique_integer([:positive, :monotonic])

    %Message{
      id: id,
      content: sequence(:message_content, &"Message content #{&1}"),
      sender: build(:user),
      channel: build(:channel),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  def dm_conversation_factory do
    # Insert both users to get real DB-assigned IDs, then sort to satisfy
    # the user_a_id < user_b_id invariant enforced at DB level.
    user1 = insert(:user)
    user2 = insert(:user)
    {a, b} = if user1.id < user2.id, do: {user1, user2}, else: {user2, user1}

    %DMConversation{
      user_a: a,
      user_b: b,
      user_a_id: a.id,
      user_b_id: b.id
    }
  end

  def dm_request_factory do
    id = 1_000_000_000_000 + System.unique_integer([:positive, :monotonic])

    %DMRequest{
      id: id,
      sender: build(:user),
      recipient: build(:user),
      preview_text: sequence(:preview_text, &"Hey, can we chat? #{&1}"),
      status: "pending"
    }
  end

  def read_cursor_factory do
    %ReadCursor{
      user: build(:user),
      channel: build(:channel),
      last_read_message_id: 0
    }
  end

  def device_token_factory do
    %DeviceToken{
      user: build(:user),
      token: sequence(:device_token, &"token-#{&1}"),
      platform: "fcm"
    }
  end

  @doc """
  Inserts a subscription for a user in a channel with the given role,
  and returns the channel.
  """
  def with_subscription(channel, user, role \\ "member") do
    insert(:subscription, %{channel: channel, user: user, role: role})
    channel
  end
end
