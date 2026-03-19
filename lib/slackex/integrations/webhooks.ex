defmodule Slackex.Integrations.Webhooks do
  @moduledoc """
  Context for managing incoming webhooks. Handles webhook creation
  (with atomic bot user + channel subscription), token verification,
  and webhook lookup.
  """

  alias Ecto.Multi
  alias Slackex.Accounts
  alias Slackex.Chat.{Channel, Subscription}
  alias Slackex.Integrations.Webhook
  alias Slackex.Repo

  @token_bytes 32

  @doc """
  Creates a webhook atomically: generates a token, creates a bot user,
  subscribes the bot to the target channel, and inserts the webhook record.

  Returns `{:ok, %{webhook: webhook, token: raw_token}}` on success,
  or `{:error, reason}` on failure.

  ## Parameters

    * `name` - Human-readable webhook name
    * `channel_id` - ID of the target channel (must be public)

  """
  def create_webhook(%{name: name, channel_id: channel_id}) do
    raw_token = generate_token()
    token_hash = hash_token(raw_token)
    bot_username = sanitize_bot_username(name)

    Multi.new()
    |> Multi.run(:channel, &resolve_channel(&1, &2, channel_id))
    |> Multi.run(:bot_user, fn _repo, _changes ->
      Accounts.create_bot_user(%{username: bot_username, display_name: name})
    end)
    |> Multi.run(:subscription, &subscribe_bot/2)
    |> Multi.insert(:webhook, fn %{channel: channel, bot_user: bot_user} ->
      Webhook.changeset(%Webhook{}, %{
        name: name,
        token_hash: token_hash,
        channel_id: channel.id,
        bot_user_id: bot_user.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{webhook: webhook}} -> {:ok, %{webhook: webhook, token: raw_token}}
      {:error, :channel, reason, _} -> {:error, reason}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp resolve_channel(repo, _changes, channel_id) do
    case repo.get(Channel, channel_id) do
      nil -> {:error, :channel_not_found}
      %Channel{is_private: true} -> {:error, :private_channel_not_supported}
      channel -> {:ok, channel}
    end
  end

  defp subscribe_bot(repo, %{channel: channel, bot_user: bot_user}) do
    %Subscription{}
    |> Subscription.changeset(%{user_id: bot_user.id, channel_id: channel.id, role: "member"})
    |> repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :channel_id])
    |> case do
      {:ok, %Subscription{user_id: nil}} -> {:ok, :already_subscribed}
      {:ok, subscription} -> {:ok, subscription}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Finds an active webhook by its token hash, preloading channel and bot_user.
  Returns `nil` if no active webhook matches.
  """
  def get_by_token_hash(hash) do
    Webhook
    |> Repo.get_by(token_hash: hash, is_active: true)
    |> preload_associations()
  end

  @doc """
  Hashes a raw token using SHA-256, returning a lowercase hex string.
  """
  def hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

  # -- Private ---------------------------------------------------------------

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end

  defp sanitize_bot_username(name) do
    sanitized =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    "webhook-#{sanitized}"
  end

  defp preload_associations(nil), do: nil
  defp preload_associations(webhook), do: Repo.preload(webhook, [:channel, :bot_user])
end
