defmodule Slackex.Chat.Message do
  @moduledoc """
  Message schema with Snowflake ID primary key and timestamp derivation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Slackex.Infrastructure.Snowflake

  @primary_key {:id, :integer, autogenerate: false}

  schema "messages" do
    field :content, Slackex.Encrypted.Binary, source: :encrypted_content
    field :edited_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :channel, Slackex.Chat.Channel
    belongs_to :dm_conversation, Slackex.Chat.DMConversation
    belongs_to :sender, Slackex.Accounts.User
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:id, :content, :sender_id, :channel_id, :dm_conversation_id, :edited_at])
    |> validate_required([:id, :content, :sender_id])
    |> validate_content_length(min: 1, max: 4000)
    |> put_inserted_at()
    |> validate_target()
  end

  defp validate_content_length(changeset, opts) do
    case get_change(changeset, :content) do
      nil ->
        changeset

      value when is_binary(value) ->
        len = String.length(value)
        min = Keyword.get(opts, :min)
        max = Keyword.get(opts, :max)

        cond do
          min && len < min ->
            add_error(changeset, :content, "should be at least %{count} character(s)",
              count: min,
              validation: :length,
              kind: :min,
              type: :string
            )

          max && len > max ->
            add_error(changeset, :content, "should be at most %{count} character(s)",
              count: max,
              validation: :length,
              kind: :max,
              type: :string
            )

          true ->
            changeset
        end

      _other ->
        changeset
    end
  end

  @milliseconds_to_microseconds 1_000

  defp put_inserted_at(changeset) do
    case get_change(changeset, :id) do
      nil ->
        changeset

      id ->
        timestamp_ms = Snowflake.extract_timestamp(id)

        inserted_at =
          DateTime.from_unix!(timestamp_ms * @milliseconds_to_microseconds, :microsecond)

        put_change(changeset, :inserted_at, inserted_at)
    end
  end

  defp validate_target(changeset) do
    case {get_field(changeset, :channel_id), get_field(changeset, :dm_conversation_id)} do
      {nil, nil} ->
        add_error(changeset, :base, "must have either channel_id or dm_conversation_id")

      {cid, did} when cid != nil and did != nil ->
        add_error(changeset, :base, "cannot have both channel_id and dm_conversation_id")

      _one_set ->
        changeset
    end
  end
end
