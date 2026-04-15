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

  alias Slackex.Accounts.User
  alias Slackex.Chat.{Channel, DMConversation, Subscription}
  alias Slackex.Notifications.{DeviceToken, Mention, OnlineTracker, Preference}
  alias Slackex.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "new_message"} = args}) do
    if FunWithFlags.enabled?(:push_notifications) do
      dispatch_channel_pushes(args)
    else
      :ok
    end
  end

  def perform(%Oban.Job{args: %{"type" => "new_dm"} = args}) do
    if FunWithFlags.enabled?(:push_notifications) do
      dispatch_dm_push(args)
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp dispatch_channel_pushes(args) do
    %{
      "channel_id" => channel_id,
      "sender_id" => sender_id,
      "content" => content,
      "sender_username" => username
    } = args

    case Repo.get(Channel, channel_id) do
      nil ->
        Logger.info("PushWorker: channel #{channel_id} deleted, discarding job")
        :ok

      channel ->
        offline_subscribers =
          channel_id
          |> subscribers_excluding(sender_id)
          |> Enum.reject(&OnlineTracker.online?(&1.user_id))

        title = "##{channel.name}"
        body = truncate_body("#{username}: #{content}", 100)

        push_to_each(offline_subscribers, channel_id, content, title, body, args)
    end
  end

  # Fan out across every subscriber so one bad token / misconfigured subscriber
  # doesn't block delivery to the rest. Accumulate the first error and return
  # it so Oban retries — retries re-pushing succeeded tokens is acceptable
  # because the client service worker dedupes on the `tag` field.
  defp push_to_each(subscribers, channel_id, content, title, body, args) do
    Enum.reduce(subscribers, :ok, fn subscriber, acc ->
      accumulate_error(
        acc,
        maybe_push_to_subscriber(subscriber, channel_id, content, title, body, args)
      )
    end)
  end

  defp accumulate_error(:ok, :ok), do: :ok
  defp accumulate_error(:ok, {:error, _} = err), do: err
  defp accumulate_error({:error, _} = existing, _next), do: existing

  defp dispatch_dm_push(args) do
    %{
      "dm_conversation_id" => dm_id,
      "sender_id" => sender_id,
      "content" => content,
      "sender_username" => username
    } = args

    case Repo.get(DMConversation, dm_id) do
      nil ->
        Logger.info("PushWorker: DM #{dm_id} deleted, discarding job")
        :ok

      dm ->
        recipient_id = if dm.user_a_id == sender_id, do: dm.user_b_id, else: dm.user_a_id
        send_dm_push_if_offline(recipient_id, username, content, args)
    end
  end

  defp maybe_push_to_subscriber(subscriber, channel_id, content, title, body, args) do
    level = Preference.resolve_level(subscriber.user_id, channel_id)

    should_notify =
      case level do
        "nothing" -> false
        "mentions" -> Mention.mentioned?(content, subscriber.username)
        _ -> true
      end

    if should_notify do
      tokens = device_tokens_for_users([subscriber.user_id])
      dispatch_all(tokens, title, body, args)
    else
      :ok
    end
  end

  defp send_dm_push_if_offline(recipient_id, username, content, args) do
    if OnlineTracker.online?(recipient_id) do
      :ok
    else
      tokens = device_tokens_for_users([recipient_id])
      body = truncate_body(content, 100)
      dispatch_all(tokens, username, body, args)
    end
  end

  # Fan out across every token for a single user so a bad token for one
  # device doesn't block delivery to the user's other devices. First error
  # is kept so Oban still retries.
  defp dispatch_all(tokens, title, body, args) do
    Enum.reduce(tokens, :ok, fn token, acc ->
      accumulate_error(acc, dispatch_push(token, title, body, args))
    end)
  end

  defp subscribers_excluding(channel_id, sender_id) do
    Repo.all(
      from s in Subscription,
        join: u in User,
        on: u.id == s.user_id,
        where: s.channel_id == ^channel_id and s.user_id != ^sender_id,
        select: %{user_id: s.user_id, username: u.username}
    )
  end

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

  defp dispatch_push(%{token: token, platform: platform}, title, body, args) do
    adapter = Application.get_env(:slackex, :push_adapter, Slackex.Notifications.PushAdapter.Stub)

    payload = %{
      "title" => title,
      "body" => body,
      "tag" => build_tag(args),
      "url" => build_url(args),
      "type" => args["type"]
    }

    adapter.send_push(token, platform, payload)
  rescue
    e -> {:error, {:exception, e.__struct__}}
  end

  defp build_tag(%{"type" => "new_message", "channel_id" => channel_id}) do
    "channel:#{channel_id}"
  end

  defp build_tag(%{"type" => "new_dm", "dm_conversation_id" => dm_id}) do
    "dm:#{dm_id}"
  end

  defp build_tag(_args), do: "general"

  defp build_url(%{"type" => "new_message"} = args) do
    slug = args["channel_slug"] || "general"
    "/chat/#{slug}"
  end

  defp build_url(%{"type" => "new_dm", "dm_conversation_id" => dm_id}) do
    "/chat/dm/#{dm_id}"
  end

  defp build_url(_args), do: "/chat"
end
