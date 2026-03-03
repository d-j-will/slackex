defmodule Slackex.Embeddings.MessageEmbedding do
  @moduledoc """
  Schema for message vector embeddings.

  Each record stores the OpenAI-generated embedding vector for a single message,
  along with a content hash to detect when re-embedding is needed. Embeddings
  are immutable -- a changed message gets a new embedding row (upsert on
  message_id), never an update.

  The primary key is `message_id` (not auto-generated) since each message
  has at most one embedding.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:message_id, :integer, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "message_embeddings" do
    field :message_inserted_at, :utc_datetime_usec
    field :channel_id, :integer
    field :dm_conversation_id, :integer
    field :embedding, Pgvector.Ecto.Vector
    field :content_hash, :string

    timestamps()
  end

  @required_fields ~w(message_id message_inserted_at content_hash inserted_at)a
  @optional_fields ~w(channel_id dm_conversation_id embedding)a

  @doc """
  Builds a changeset for a MessageEmbedding.

  Requires `message_id`, `message_inserted_at`, `content_hash`, and `inserted_at`.
  Validates that `content_hash` is exactly 64 characters (SHA-256 hex digest).
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(embedding, attrs) do
    embedding
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:content_hash, is: 64)
  end
end
