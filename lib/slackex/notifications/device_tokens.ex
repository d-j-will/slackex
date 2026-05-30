defmodule Slackex.Notifications.DeviceTokens do
  @moduledoc """
  Persistence for web-push `DeviceToken` rows: register, remove, heal, and
  existence checks.

  Extracted from `SlackexWeb.ChatLive.Index` so token CRUD lives in the
  Notifications context (not the web layer) and is unit-testable without a
  LiveView. All operations key on `{token, user_id}`, which the schema treats
  as the unique identity of a browser subscription.
  """

  import Ecto.Query

  require Logger

  alias Slackex.Notifications.DeviceToken
  alias Slackex.Repo

  @platform "web_push"
  @device_name "PWA"

  @doc """
  Registers (or refreshes) the user's web-push token. Idempotent on
  `{token, user_id}` — an existing row is updated rather than duplicated.
  """
  def register(user_id, subscription_json) do
    base = Repo.get_by(DeviceToken, token: subscription_json, user_id: user_id) || %DeviceToken{}

    base
    |> DeviceToken.changeset(attrs(user_id, subscription_json))
    |> Repo.insert_or_update()
  end

  @doc "Removes the user's token matching `subscription_json`, if present. Always `:ok`."
  def remove(user_id, subscription_json) do
    case Repo.get_by(DeviceToken, token: subscription_json, user_id: user_id) do
      nil -> :ok
      token -> _ = Repo.delete(token)
    end

    :ok
  end

  @doc "Whether the user has at least one push `DeviceToken` row."
  def exists?(user_id) do
    Repo.exists?(from(dt in DeviceToken, where: dt.user_id == ^user_id))
  end

  @doc """
  Auto-heal: when the browser still holds a push subscription but our
  `DeviceToken` row was lost (deploy hiccup, expired-cleanup desync, etc.),
  re-register it so the UI's "Enabled" badge reflects deliverability.

  Idempotent — returns `:noop` when the client is not subscribed, the
  subscription is missing, or a matching token already exists; `:healed` when a
  token was (re)inserted.
  """
  def maybe_heal(user_id, true, subscription_json) when is_binary(subscription_json) do
    if Repo.get_by(DeviceToken, token: subscription_json, user_id: user_id) do
      :noop
    else
      Logger.info("Auto-healing missing device token for user #{user_id}")
      _ = register(user_id, subscription_json)
      :healed
    end
  end

  def maybe_heal(_user_id, _subscribed, _subscription), do: :noop

  defp attrs(user_id, subscription_json) do
    %{
      "user_id" => user_id,
      "token" => subscription_json,
      "platform" => @platform,
      "device_name" => @device_name
    }
  end
end
