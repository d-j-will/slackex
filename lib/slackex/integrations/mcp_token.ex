defmodule Slackex.Integrations.McpToken do
  @moduledoc """
  MCP token schema. Represents a bearer token that grants an AI agent
  access to the Tenun MCP server via a bot user identity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "mcp_tokens" do
    field :name, :string
    field :token_hash, :string
    field :is_active, :boolean, default: true
    field :last_used_at, :utc_datetime_usec

    belongs_to :bot_user, Slackex.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(mcp_token, attrs) do
    mcp_token
    |> cast(attrs, [:name, :token_hash, :bot_user_id, :is_active, :last_used_at])
    |> validate_required([:name, :token_hash, :bot_user_id])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:bot_user_id)
  end
end
