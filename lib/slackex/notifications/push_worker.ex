defmodule Slackex.Notifications.PushWorker do
  @moduledoc """
  Oban worker that dispatches push notifications to FCM/APNs.

  Handles two job types:
  - `"new_message"` — notifies offline channel subscribers (excluding sender)
  - `"new_dm"` — notifies offline DM recipient

  Actual push dispatch is delegated to a configurable adapter
  (default: `Slackex.Notifications.PushAdapter.Stub`). Configure via:

      config :slackex, :push_adapter, MyApp.FCMAdapter
  """

  use Oban.Worker, queue: :notifications, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Slackex.Chat.{Channel, DMConversation, Subscription}
  alias Slackex.Notifications.{DeviceToken, OnlineTracker}
  alias Slackex.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "new_message"} = args}) do
    %{
      "channel_id" => channel_id,
      "sender_id" => sender_id,
      "content" => content,
      "sender_username" => username
    } = args

    channel = Repo.get!(Channel, channel_id)

    offline_subscriber_ids =
      channel_id
      |> subscriber_ids_excluding(sender_id)
      |> Enum.reject(&OnlineTracker.online?/1)

    tokens = device_tokens_for_users(offline_subscriber_ids)

    if tokens != [] do
      title = "##{channel.name}"
      body = truncate_body("#{username}: #{content}", 100)
      Enum.each(tokens, &dispatch_push(&1, title, body))
    end

    :ok
  end

  def perform(%Oban.Job{args: %{"type" => "new_dm"} = args}) do
    %{
      "dm_conversation_id" => dm_id,
      "sender_id" => sender_id,
      "content" => content,
      "sender_username" => username
    } = args

    dm = Repo.get!(DMConversation, dm_id)
    recipient_id = if dm.user_a_id == sender_id, do: dm.user_b_id, else: dm.user_a_id

    if OnlineTracker.online?(recipient_id) do
      :ok
    else
      tokens = device_tokens_for_users([recipient_id])
      body = truncate_body(content, 100)
      Enum.each(tokens, &dispatch_push(&1, username, body))
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp subscriber_ids_excluding(channel_id, sender_id) do
    Repo.all(
      from s in Subscription,
        where: s.channel_id == ^channel_id and s.user_id != ^sender_id,
        select: s.user_id
    )
  end

  defp device_tokens_for_users([]), do: []

  defp device_tokens_for_users(user_ids) do
    Repo.all(
      from dt in DeviceToken,
        where: dt.user_id in ^user_ids,
        select: %{token: dt.token, platform: dt.platform}
    )
  end

  defp truncate_body(text, max_len) when byte_size(text) > max_len do
    String.slice(text, 0, max_len - 3) <> "..."
  end

  defp truncate_body(text, _max_len), do: text

  defp dispatch_push(%{token: token, platform: platform}, title, body) do
    adapter = Application.get_env(:slackex, :push_adapter, Slackex.Notifications.PushAdapter.Stub)
    adapter.send_push(token, platform, title, body)
  rescue
    e -> Logger.warning("Push dispatch failed: #{inspect(e)}")
  end
end
