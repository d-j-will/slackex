defmodule Slackex.Integrations.McpTokens do
  @moduledoc """
  Context for managing MCP tokens. Handles token creation (with atomic
  bot user), lookup, revocation, and last-used tracking.
  """

  alias Ecto.Multi
  alias Slackex.Accounts
  alias Slackex.Integrations.McpToken
  alias Slackex.Repo

  @token_bytes 32

  def create_mcp_token(%{name: name}) do
    raw_token = generate_token()
    token_hash = hash_token(raw_token)
    bot_username = sanitize_bot_username(name)

    Multi.new()
    |> Multi.run(:bot_user, fn _repo, _changes ->
      Accounts.create_bot_user(%{username: bot_username, display_name: name})
    end)
    |> Multi.insert(:mcp_token, fn %{bot_user: bot_user} ->
      McpToken.changeset(%McpToken{}, %{
        name: name,
        token_hash: token_hash,
        bot_user_id: bot_user.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{mcp_token: token, bot_user: bot_user}} ->
        {:ok, %{mcp_token: token, raw_token: raw_token, bot_user: bot_user}}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  def get_by_token_hash(hash) do
    McpToken
    |> Repo.get_by(token_hash: hash, is_active: true)
    |> Repo.preload(:bot_user)
  end

  def hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

  def revoke_mcp_token(%McpToken{} = token) do
    token
    |> Ecto.Changeset.change(is_active: false)
    |> Repo.update()
  end

  @touch_debounce_seconds 300

  def touch_last_used(%McpToken{last_used_at: nil} = token) do
    do_touch(token)
  end

  def touch_last_used(%McpToken{last_used_at: last} = token) do
    if DateTime.diff(DateTime.utc_now(), last, :second) >= @touch_debounce_seconds do
      do_touch(token)
    else
      :debounced
    end
  end

  defp do_touch(token) do
    token
    |> Ecto.Changeset.change(last_used_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp generate_token do
    raw = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
    "mcp_" <> raw
  end

  defp sanitize_bot_username(name) do
    sanitized =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")
      |> String.slice(0, 35)

    "mcp-" <> sanitized
  end
end
