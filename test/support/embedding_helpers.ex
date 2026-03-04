defmodule Slackex.EmbeddingHelpers do
  @moduledoc """
  Shared test helpers for embedding and search tests.

  Provides factory-like functions for creating messages with search_content
  populated and for creating message embeddings via the StubClient.
  """

  import Ecto.Query
  import Slackex.Factory

  alias Slackex.Chat
  alias Slackex.Chat.Message
  alias Slackex.Embeddings.{EmbeddingClient, MessageEmbedding}
  alias Slackex.Repo

  @doc """
  Inserts a message in a channel with `search_content` populated.

  ExMachina bypasses changesets, so `search_content` is not set automatically.
  This helper updates the row directly after insert.
  """
  def insert_channel_message(channel, sender, content) do
    msg = insert(:message, channel: channel, sender: sender, content: content)

    {1, _} =
      from(m in Message, where: m.id == ^msg.id)
      |> Repo.update_all(set: [search_content: content])

    Repo.get!(Message, msg.id)
  end

  @doc """
  Inserts a DM message with `search_content` populated.
  """
  def insert_dm_message(dm_conversation, sender, content) do
    msg =
      insert(:message,
        channel: nil,
        channel_id: nil,
        dm_conversation: dm_conversation,
        sender: sender,
        content: content
      )

    {1, _} =
      from(m in Message, where: m.id == ^msg.id)
      |> Repo.update_all(set: [search_content: content])

    Repo.get!(Message, msg.id)
  end

  @doc """
  Creates a MessageEmbedding for the given message using the configured
  EmbeddingClient (StubClient in test).
  """
  def embed_message(message) do
    content = message.content || message.search_content || ""
    {:ok, vector} = EmbeddingClient.generate(content)
    content_hash = compute_content_hash(content)

    %MessageEmbedding{
      message_id: message.id,
      message_inserted_at: message.inserted_at,
      channel_id: message.channel_id,
      dm_conversation_id: message.dm_conversation_id,
      embedding: Pgvector.new(vector),
      content_hash: content_hash,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
    |> Repo.insert!()
  end

  @doc """
  Creates a MessageEmbedding with a specific vector (for threshold testing).
  """
  def embed_message_with_vector(message, vector) do
    content = message.content || message.search_content || ""
    content_hash = compute_content_hash(content)

    %MessageEmbedding{
      message_id: message.id,
      message_inserted_at: message.inserted_at,
      channel_id: message.channel_id,
      dm_conversation_id: message.dm_conversation_id,
      embedding: Pgvector.new(vector),
      content_hash: content_hash,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
    |> Repo.insert!()
  end

  @doc """
  Creates a public channel with the given user as owner.
  """
  def create_public_channel(creator) do
    channel = insert(:channel, creator: creator, is_private: false)
    insert(:subscription, user: creator, channel: channel, role: "owner")
    channel
  end

  @doc """
  Creates a private channel with the given user as owner.
  """
  def create_private_channel(creator) do
    channel = insert(:channel, creator: creator, is_private: true)
    insert(:subscription, user: creator, channel: channel, role: "owner")
    channel
  end

  @doc """
  Subscribes a user to a channel as a member.
  """
  def subscribe_user_to_channel(channel, user) do
    insert(:subscription, user: user, channel: channel, role: "member")
  end

  @doc """
  Sends a message in a channel via the Chat context.
  """
  def send_channel_message(channel, sender, content) do
    {:ok, message} = Chat.send_message(channel.id, sender.id, content)
    message
  end

  @doc """
  Sends a DM via the Chat context.
  """
  def send_dm_message(dm, sender, content) do
    {:ok, message} = Chat.send_dm(dm.id, sender.id, content)
    message
  end

  @doc """
  Creates a DM conversation between two users.
  """
  def create_dm_conversation(user_a, user_b) do
    {a, b} = if user_a.id < user_b.id, do: {user_a, user_b}, else: {user_b, user_a}

    %Slackex.Chat.DMConversation{}
    |> Ecto.Changeset.change(%{user_a_id: a.id, user_b_id: b.id})
    |> Repo.insert!()
  end

  @doc """
  Builds a unit vector with value 1.0 at the given index, 0.0 elsewhere.
  Useful for creating orthogonal vectors with known cosine similarity.
  """
  def basis_vector(index, dimensions \\ EmbeddingClient.dimensions()) do
    Enum.map(0..(dimensions - 1), fn i ->
      if i == index, do: 1.0, else: 0.0
    end)
  end

  @doc """
  Computes SHA-256 hex digest of the given content.
  """
  def compute_content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
