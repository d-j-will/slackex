defmodule Slackex.Analytics.Event do
  @moduledoc """
  Ecto schema for analytics events with Snowflake ID primary key.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Slackex.Infrastructure.Snowflake

  @primary_key {:id, :integer, autogenerate: false}

  @valid_event_types ~w(page_view feature_used js_error server_error oban_error performance click)
  @valid_categories ~w(product error performance)

  schema "analytics_events" do
    field :event_type, :string
    field :event_category, :string
    field :event_name, :string
    field :user_id, :integer
    field :session_id, :string
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :event_category, :event_name, :user_id, :session_id, :metadata])
    |> validate_required([:event_type, :event_category, :event_name])
    |> validate_inclusion(:event_type, @valid_event_types)
    |> validate_inclusion(:event_category, @valid_categories)
    |> put_snowflake_id()
    |> put_inserted_at()
  end

  defp put_snowflake_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, Snowflake.generate())
      _ -> changeset
    end
  end

  defp put_inserted_at(changeset) do
    case get_field(changeset, :inserted_at) do
      nil ->
        put_change(changeset, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

      _ ->
        changeset
    end
  end
end
