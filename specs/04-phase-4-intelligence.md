# Phase 4 — Intelligence & Search

## Goal

Add full-text search, pgvector-based semantic search, and an embedding generation pipeline. This phase makes chat history searchable via both keyword and meaning, and lays the foundation for future AI/RAG features (conversation summaries, intelligent Q&A over channel history).

## Prerequisites

Phase 3 complete and all acceptance criteria met.

## Dependencies Added

```elixir
# Add to mix.exs deps
{:pgvector, "~> 0.3"},
{:req, "~> 0.5"},        # HTTP client for embedding API calls
```

## Step 1: Enable pgvector Extension

### 1.1 Migration

```elixir
defmodule Slackex.Repo.Migrations.EnablePgvector do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
```

### 1.2 Message Embeddings Table

```elixir
defmodule Slackex.Repo.Migrations.CreateMessageEmbeddings do
  use Ecto.Migration

  @doc """
  NOTE: message_id is NOT a foreign key to the messages table.
  After Phase 3, messages is a partitioned table with composite PK (id, inserted_at).
  PostgreSQL does not support FK references to partitioned tables unless the FK
  includes the full partition key. Since embeddings are derived data, we enforce
  referential integrity at the application level instead. Orphaned embeddings
  (from deleted messages) are harmless and can be cleaned by a periodic Oban job.
  """
  def change do
    create table(:message_embeddings, primary_key: false) do
      add :message_id, :bigint, primary_key: true  # References messages.id (no FK constraint)
      add :channel_id, :bigint
      add :embedding, :vector, size: 1536    # OpenAI text-embedding-3-small dimensions
      add :content_hash, :string, size: 64   # SHA-256 of content, for dedup

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:message_embeddings, [:channel_id])

    # HNSW index for fast approximate nearest neighbor search
    # ef_construction: build quality (higher = better recall, slower build)
    # m: connections per layer (higher = better recall, more memory)
    execute(
      """
      CREATE INDEX idx_embeddings_hnsw ON message_embeddings
        USING hnsw (embedding vector_cosine_ops)
        WITH (m = 16, ef_construction = 64)
      """,
      "DROP INDEX idx_embeddings_hnsw"
    )
  end
end
```

## Step 2: Embedding Schema

```elixir
defmodule Slackex.Chat.MessageEmbedding do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:message_id, :integer, autogenerate: false}

  schema "message_embeddings" do
    field :channel_id, :integer
    field :embedding, Pgvector.Ecto.Vector
    field :content_hash, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(embedding, attrs) do
    embedding
    |> cast(attrs, [:message_id, :channel_id, :embedding, :content_hash])
    |> validate_required([:message_id, :embedding, :content_hash])
  end
end
```

## Step 3: Embedding Client

### 3.1 Configurable Embedding Provider

```elixir
defmodule Slackex.Embeddings.EmbeddingClient do
  @moduledoc """
  Client for generating text embeddings.
  Supports OpenAI, local models, or any provider implementing the behaviour.
  """

  @callback generate(text :: String.t()) :: {:ok, [float()]} | {:error, term()}
  @callback generate_batch(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  @callback dimensions() :: pos_integer()

  @doc "Get the configured embedding client module."
  def client do
    Application.get_env(:slackex, :embedding_client, Slackex.Embeddings.OpenAIClient)
  end

  def generate(text), do: client().generate(text)
  def generate_batch(texts), do: client().generate_batch(texts)
  def dimensions, do: client().dimensions()
end
```

### 3.2 OpenAI Implementation

```elixir
defmodule Slackex.Embeddings.OpenAIClient do
  @behaviour Slackex.Embeddings.EmbeddingClient

  @model "text-embedding-3-small"
  @dimensions 1536
  @api_url "https://api.openai.com/v1/embeddings"
  @max_batch_size 100

  @impl true
  def dimensions, do: @dimensions

  @impl true
  def generate(text) do
    case generate_batch([text]) do
      {:ok, [embedding]} -> {:ok, embedding}
      error -> error
    end
  end

  @impl true
  def generate_batch(texts) when length(texts) <= @max_batch_size do
    api_key = Application.fetch_env!(:slackex, :openai_api_key)

    body = %{
      model: @model,
      input: texts,
      dimensions: @dimensions
    }

    case Req.post(@api_url,
      json: body,
      headers: [{"authorization", "Bearer #{api_key}"}],
      receive_timeout: 30_000
    ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        embeddings = data
        |> Enum.sort_by(& &1["index"])
        |> Enum.map(& &1["embedding"])
        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def generate_batch(texts) when length(texts) > @max_batch_size do
    texts
    |> Enum.chunk_every(@max_batch_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case generate_batch(chunk) do
        {:ok, embeddings} -> {:cont, {:ok, acc ++ embeddings}}
        error -> {:halt, error}
      end
    end)
  end
end
```

### 3.3 Stub Client for Test/Dev

```elixir
defmodule Slackex.Embeddings.StubClient do
  @moduledoc "Generates deterministic fake embeddings for testing."
  @behaviour Slackex.Embeddings.EmbeddingClient

  @dimensions 1536

  @impl true
  def dimensions, do: @dimensions

  @impl true
  def generate(text) do
    {:ok, deterministic_embedding(text)}
  end

  @impl true
  def generate_batch(texts) do
    {:ok, Enum.map(texts, &deterministic_embedding/1)}
  end

  defp deterministic_embedding(text) do
    # Generate a deterministic embedding based on text hash
    # Similar texts will have similar (but not identical) embeddings
    seed = :erlang.phash2(text)
    :rand.seed(:exsss, {seed, seed, seed})

    for _ <- 1..@dimensions do
      :rand.uniform() * 2 - 1  # Values between -1 and 1
    end
    |> normalize()
  end

  defp normalize(vector) do
    magnitude = :math.sqrt(Enum.reduce(vector, 0, fn x, acc -> acc + x * x end))
    Enum.map(vector, &(&1 / magnitude))
  end
end
```

```elixir
# config/test.exs
config :slackex, :embedding_client, Slackex.Embeddings.StubClient

# config/dev.exs
config :slackex, :embedding_client, Slackex.Embeddings.StubClient  # Or OpenAIClient if API key set
```

## Step 4: Embedding Generation Worker

### 4.1 Oban Worker

```elixir
defmodule Slackex.Embeddings.EmbeddingWorker do
  @moduledoc """
  Generates vector embeddings for messages asynchronously.
  Runs as an Oban worker in the :embeddings queue.
  Batches messages for efficient API usage.
  """
  use Oban.Worker, queue: :embeddings, max_attempts: 3, priority: 3

  alias Slackex.Repo
  alias Slackex.Chat.MessageEmbedding
  alias Slackex.Embeddings.EmbeddingClient

  @batch_size 50

  @impl true
  def perform(%Oban.Job{args: %{"message_ids" => message_ids}}) do
    # Fetch messages that don't already have embeddings
    messages = fetch_unembedded_messages(message_ids)

    if messages == [] do
      :ok
    else
      texts = Enum.map(messages, & &1.content)

      case EmbeddingClient.generate_batch(texts) do
        {:ok, embeddings} ->
          insert_embeddings(messages, embeddings)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def perform(%Oban.Job{args: %{"channel_id" => channel_id, "backfill" => true}}) do
    # Backfill embeddings for an entire channel
    stream_unembedded_messages(channel_id)
    |> Stream.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      texts = Enum.map(batch, & &1.content)

      case EmbeddingClient.generate_batch(texts) do
        {:ok, embeddings} -> insert_embeddings(batch, embeddings)
        {:error, _} -> :ok  # Log and continue, don't fail entire backfill
      end

      # Rate limiting: pause between batches
      Process.sleep(1_000)
    end)

    :ok
  end

  # --- Enqueue helpers ---

  @doc "Enqueue embedding generation for a batch of message IDs."
  def enqueue(message_ids) when is_list(message_ids) do
    message_ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn chunk ->
      %{message_ids: chunk}
      |> new(priority: 3)  # Low priority — don't compete with notifications
      |> Oban.insert()
    end)
  end

  @doc "Enqueue a full channel backfill."
  def enqueue_backfill(channel_id) do
    %{channel_id: channel_id, backfill: true}
    |> new(priority: 3, unique: [period: 3600, fields: [:args]])
    |> Oban.insert()
  end

  # --- Private ---

  defp fetch_unembedded_messages(message_ids) do
    import Ecto.Query

    from(m in Slackex.Chat.Message,
      left_join: e in MessageEmbedding, on: e.message_id == m.id,
      where: m.id in ^message_ids and is_nil(e.message_id),
      select: m
    )
    |> Repo.all()
  end

  defp stream_unembedded_messages(channel_id) do
    import Ecto.Query

    from(m in Slackex.Chat.Message,
      left_join: e in MessageEmbedding, on: e.message_id == m.id,
      where: m.channel_id == ^channel_id and is_nil(e.message_id),
      order_by: [asc: m.id],
      select: m
    )
    |> Repo.stream(max_rows: 500)
  end

  defp insert_embeddings(messages, embeddings) do
    entries = Enum.zip(messages, embeddings)
    |> Enum.map(fn {msg, embedding} ->
      %{
        message_id: msg.id,
        channel_id: msg.channel_id,
        embedding: embedding,
        content_hash: :crypto.hash(:sha256, msg.content) |> Base.encode16(case: :lower),
        inserted_at: DateTime.utc_now()
      }
    end)

    Repo.insert_all(MessageEmbedding, entries, on_conflict: :nothing, conflict_target: [:message_id])
  end
end
```

### 4.2 Hook into Broadway Pipeline

Update the Broadway pipeline to enqueue embedding jobs after successful persistence:

```elixir
# In Slackex.Pipeline.MessagePipeline:

@impl true
def handle_batch(:postgres, messages, _batch_info, _context) do
  message_data = Enum.map(messages, & &1.data)

  # 1. Persist to PostgreSQL
  BatchWriter.insert_batch(message_data)

  # 2. Enqueue embedding generation (async, low priority)
  message_ids = Enum.map(message_data, & &1.id)
  Slackex.Embeddings.EmbeddingWorker.enqueue(message_ids)

  messages
end
```

## Step 5: Search Module

### 5.1 Full-Text Search

```elixir
defmodule Slackex.Search.MessageSearch do
  @moduledoc """
  Combined full-text and semantic search over message history.
  """

  import Ecto.Query
  alias Slackex.Repo
  alias Slackex.Chat.{Message, MessageEmbedding}
  alias Slackex.Embeddings.EmbeddingClient

  @doc """
  Full-text keyword search using PostgreSQL tsvector.
  Returns messages matching the query, ranked by relevance.
  """
  def text_search(query, opts \\ []) do
    channel_id = Keyword.get(opts, :channel_id)
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    base_query = from(m in Message,
      where: fragment(
        "to_tsvector('english', ?) @@ plainto_tsquery('english', ?)",
        m.content, ^query
      ),
      order_by: [desc: fragment(
        "ts_rank(to_tsvector('english', ?), plainto_tsquery('english', ?))",
        m.content, ^query
      )],
      limit: ^limit,
      offset: ^offset,
      preload: [:sender]
    )

    base_query
    |> maybe_filter_channel(channel_id)
    |> Repo.all()
  end

  @doc """
  Semantic search using pgvector cosine similarity.
  Finds messages with similar meaning to the query, even if different words are used.
  """
  def semantic_search(query, opts \\ []) do
    channel_id = Keyword.get(opts, :channel_id)
    limit = Keyword.get(opts, :limit, 20)
    threshold = Keyword.get(opts, :threshold, 0.3)  # Minimum similarity

    case EmbeddingClient.generate(query) do
      {:ok, query_embedding} ->
        results = from(e in MessageEmbedding,
          join: m in Message, on: m.id == e.message_id,
          where: fragment(
            "1 - (? <=> ?::vector) > ?",
            e.embedding,
            ^Pgvector.new(query_embedding),
            ^threshold
          ),
          order_by: [asc: fragment("? <=> ?::vector", e.embedding, ^Pgvector.new(query_embedding))],
          limit: ^limit,
          select: %{
            message: m,
            similarity: fragment(
              "1 - (? <=> ?::vector)",
              e.embedding,
              ^Pgvector.new(query_embedding)
            )
          }
        )
        |> maybe_filter_channel_embedding(channel_id)
        |> Repo.all()
        |> Enum.map(fn %{message: msg, similarity: sim} ->
          msg
          |> Repo.preload(:sender)
          |> Map.put(:similarity, sim)
        end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Hybrid search: combines FTS keyword ranking with semantic similarity.
  Uses Reciprocal Rank Fusion (RRF) to merge result lists.
  """
  def hybrid_search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    # Run both searches in parallel
    text_task = Task.async(fn -> text_search(query, opts ++ [limit: limit * 2]) end)
    semantic_task = Task.async(fn -> semantic_search(query, opts ++ [limit: limit * 2]) end)

    text_results = Task.await(text_task, 10_000)
    semantic_results = case Task.await(semantic_task, 10_000) do
      {:ok, results} -> results
      {:error, _} -> []
    end

    # Reciprocal Rank Fusion
    k = 60  # RRF constant

    text_scores = text_results
    |> Enum.with_index(1)
    |> Map.new(fn {msg, rank} -> {msg.id, 1.0 / (k + rank)} end)

    semantic_scores = semantic_results
    |> Enum.with_index(1)
    |> Map.new(fn {msg, rank} -> {msg.id, 1.0 / (k + rank)} end)

    # Merge scores
    all_ids = MapSet.union(MapSet.new(Map.keys(text_scores)), MapSet.new(Map.keys(semantic_scores)))

    all_messages = Map.new(
      text_results ++ semantic_results,
      fn msg -> {msg.id, msg} end
    )

    all_ids
    |> Enum.map(fn id ->
      score = Map.get(text_scores, id, 0) + Map.get(semantic_scores, id, 0)
      {Map.get(all_messages, id), score}
    end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {msg, score} -> Map.put(msg, :search_score, score) end)
  end

  # --- Private ---

  defp maybe_filter_channel(query, nil), do: query
  defp maybe_filter_channel(query, channel_id) do
    where(query, [m], m.channel_id == ^channel_id)
  end

  defp maybe_filter_channel_embedding(query, nil), do: query
  defp maybe_filter_channel_embedding(query, channel_id) do
    where(query, [e, m], e.channel_id == ^channel_id)
  end
end
```

### 5.2 Search Context (Public API)

```elixir
defmodule Slackex.Search do
  use Boundary,
    deps: [Slackex.Chat, Slackex.Cache, Slackex.Embeddings],
    exports: [MessageSearch, HistoryLoader]

  alias Slackex.Search.MessageSearch

  @doc """
  Search messages using the specified mode.
  Modes: :text (FTS), :semantic (pgvector), :hybrid (both with RRF)
  """
  def search_messages(query, opts \\ []) do
    mode = Keyword.get(opts, :mode, :hybrid)

    case mode do
      :text -> {:ok, MessageSearch.text_search(query, opts)}
      :semantic -> MessageSearch.semantic_search(query, opts)
      :hybrid -> {:ok, MessageSearch.hybrid_search(query, opts)}
    end
  end
end
```

## Step 6: Search LiveView Component

```elixir
defmodule SlackexWeb.ChatLive.SearchComponent do
  use SlackexWeb, :live_component

  alias Slackex.Search

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:search_mode, :hybrid)
     |> assign(:searching, false)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) when byte_size(query) >= 2 do
    send(self(), {:perform_search, query, socket.assigns.search_mode})

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:searching, true)}
  end

  def handle_event("search", _params, socket) do
    {:noreply, assign(socket, :results, [])}
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) do
    mode = case mode do
      "text" -> :text
      "semantic" -> :semantic
      "hybrid" -> :hybrid
      _ -> :hybrid
    end

    {:noreply, assign(socket, :search_mode, mode)}
  end

  def handle_event("jump_to_message", %{"message-id" => message_id, "channel-id" => channel_id}, socket) do
    send(self(), {:jump_to_message, String.to_integer(channel_id), String.to_integer(message_id)})
    {:noreply, socket}
  end

  @impl true
  def update(%{search_results: results}, socket) do
    {:ok, assign(socket, results: results, searching: false)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end
end
```

Handle the async search in the parent LiveView:

```elixir
# In ChatLive.Index:

@impl true
def handle_info({:perform_search, query, mode}, socket) do
  case Search.search_messages(query, mode: mode, channel_id: get_active_channel_id(socket)) do
    {:ok, results} ->
      send_update(SlackexWeb.ChatLive.SearchComponent,
        id: "search",
        search_results: results
      )
    {:error, _} ->
      send_update(SlackexWeb.ChatLive.SearchComponent,
        id: "search",
        search_results: []
      )
  end

  {:noreply, socket}
end

def handle_info({:jump_to_message, channel_id, message_id}, socket) do
  # Navigate to the channel and scroll to the message
  channel = Slackex.Chat.get_channel!(channel_id)
  messages = Slackex.Chat.list_messages_around(channel_id, message_id, limit: 50)

  {:noreply,
   socket
   |> activate_channel(channel)
   |> stream(:messages, messages, reset: true)
   |> push_event("scroll_to_message", %{message_id: message_id})}
end
```

## Step 7: RAG-Ready Query Interface

This is the foundation for future AI features. It exposes a function that retrieves relevant context for an LLM:

```elixir
defmodule Slackex.Embeddings.RAGContext do
  @moduledoc """
  Retrieves relevant message context for RAG (Retrieval-Augmented Generation).
  Used to provide conversation history to LLMs for:
  - Channel summaries
  - Q&A over chat history
  - Intelligent search explanations
  """

  alias Slackex.Search.MessageSearch

  @doc """
  Retrieve the most relevant messages for a given query.
  Returns formatted context suitable for LLM consumption.
  """
  def retrieve(query, opts \\ []) do
    channel_id = Keyword.get(opts, :channel_id)
    max_tokens = Keyword.get(opts, :max_tokens, 4000)
    limit = Keyword.get(opts, :limit, 30)

    case MessageSearch.semantic_search(query, channel_id: channel_id, limit: limit) do
      {:ok, messages} ->
        context = messages
        |> Enum.map(&format_message/1)
        |> truncate_to_tokens(max_tokens)
        |> Enum.join("\n")

        {:ok, context, length(messages)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_message(message) do
    timestamp = Calendar.strftime(message.inserted_at, "%Y-%m-%d %H:%M")
    username = if message.sender, do: message.sender.username, else: "unknown"
    "[#{timestamp}] #{username}: #{message.content}"
  end

  defp truncate_to_tokens(lines, max_tokens) do
    # Rough estimate: 1 token ≈ 4 characters
    max_chars = max_tokens * 4

    {selected, _remaining} = Enum.reduce(lines, {[], 0}, fn line, {acc, chars} ->
      new_chars = chars + String.length(line) + 1
      if new_chars <= max_chars do
        {[line | acc], new_chars}
      else
        {acc, chars}
      end
    end)

    Enum.reverse(selected)
  end
end
```

## Step 8: Embeddings Boundary

```elixir
defmodule Slackex.Embeddings do
  use Boundary,
    deps: [Slackex.Chat],
    exports: [EmbeddingWorker, EmbeddingClient, RAGContext]
end
```

## Step 9: Configuration

```elixir
# config/config.exs
config :slackex, :embedding_client, Slackex.Embeddings.OpenAIClient

# config/dev.exs
config :slackex, :embedding_client, Slackex.Embeddings.StubClient

# config/test.exs
config :slackex, :embedding_client, Slackex.Embeddings.StubClient

# config/runtime.exs
if config_env() == :prod do
  config :slackex, :openai_api_key, System.fetch_env!("OPENAI_API_KEY")
end
```

## Phase 4 Acceptance Criteria

- [ ] pgvector extension is enabled and message_embeddings table exists with HNSW index
- [ ] Full-text search returns relevant messages ranked by ts_rank
- [ ] Semantic search finds messages with similar meaning (not just matching words)
- [ ] Hybrid search merges FTS and semantic results using Reciprocal Rank Fusion
- [ ] Search can be scoped to a specific channel or search all channels
- [ ] Embedding worker generates embeddings asynchronously via Oban
- [ ] Embedding generation is triggered automatically after message persistence in Broadway
- [ ] Batch embedding supports up to 100 texts per API call
- [ ] Channel backfill job can generate embeddings for existing message history
- [ ] Stub embedding client works in test/dev without an API key
- [ ] Search UI in LiveView shows results with highlighted matches
- [ ] "Jump to message" navigates to the correct channel and scrolls to the message
- [ ] RAGContext.retrieve/2 returns formatted context suitable for LLM consumption
- [ ] Search works across partitioned message tables transparently
- [ ] All behavioral tests from Phases 1-3 still pass
- [ ] New behavioral tests cover: FTS search, semantic search, embedding generation
