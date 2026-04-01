defmodule Slackex.TestFactory do
  @moduledoc false

  use ExMachina.Ecto, repo: Slackex.Repo

  import Ecto.Query, only: [from: 2]

  alias Slackex.Accounts.User

  alias Slackex.Chat.{
    AbuseReport,
    Channel,
    DMConversation,
    DMRequest,
    Message,
    MessageReaction,
    ReadCursor,
    Subscription
  }

  alias Slackex.Analytics.Event, as: AnalyticsEvent
  alias Slackex.Notifications.DeviceToken
  alias Slackex.Repo

  def user_factory(attrs) do
    email = Map.get(attrs, :email, sequence(:email, &"user#{&1}@example.com"))

    user = %User{
      username: sequence(:username, &"user#{&1}"),
      display_name: sequence(:display_name, &"User #{&1}"),
      email: email,
      email_hash: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123"),
      status: "offline"
    }

    merge_attributes(user, Map.delete(attrs, :email))
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
    %Message{
      id: unique_bigint_id(),
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
    %DMRequest{
      id: unique_bigint_id(),
      sender: build(:user),
      recipient: build(:user),
      preview_text: sequence(:preview_text, &"Hey, can we chat? #{&1}"),
      status: "pending"
    }
  end

  def message_reaction_factory do
    %MessageReaction{
      emoji: "👍",
      user: build(:user),
      message: build(:message)
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

  @doc """
  Inserts a user with `inserted_at` backdated by the given number of hours.
  Useful for testing account-age gates in DM safety checks.
  """
  def insert_user_with_age(hours_ago) do
    user = insert(:user)

    past =
      DateTime.utc_now()
      |> DateTime.add(-hours_ago * 3600, :second)
      |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(u in Slackex.Accounts.User, where: u.id == ^user.id),
        set: [inserted_at: past]
      )

    %{user | inserted_at: past}
  end

  @doc """
  Inserts a user with `inserted_at` backdated by the given number of days.
  """
  def insert_user_with_age_days(days_ago) do
    insert_user_with_age(days_ago * 24)
  end

  @doc """
  Creates an abuse report with a backdated inserted_at timestamp.
  Useful for testing time-window-dependent logic (dampening, velocity).
  """
  def insert_backdated_abuse_report(reporter, reported, category, hours_ago) do
    report_attrs = %{
      reporter_id: reporter.id,
      reported_user_id: reported.id,
      category: category,
      status: "open"
    }

    {:ok, report} =
      %AbuseReport{id: unique_bigint_id()}
      |> AbuseReport.changeset(report_attrs)
      |> Repo.insert()

    past =
      DateTime.utc_now()
      |> DateTime.add(-hours_ago * 3600, :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(ar in AbuseReport, where: ar.id == ^report.id),
      set: [inserted_at: past]
    )

    %{report | inserted_at: past}
  end

  def analytics_event_factory do
    %AnalyticsEvent{
      id: unique_bigint_id(),
      event_type: "page_view",
      event_category: "product",
      event_name: sequence(:event_name, &"event_#{&1}"),
      session_id: Ecto.UUID.generate(),
      metadata: %{"path" => "/chat/general"},
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  # Generates a large monotonic integer suitable as a bigint ID.
  # Not a real Snowflake, but valid for factory use where the Snowflake
  # GenServer is not started.
  defp unique_bigint_id do
    1_000_000_000_000 + System.unique_integer([:positive, :monotonic])
  end
end
