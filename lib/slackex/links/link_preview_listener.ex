defmodule Slackex.Links.LinkPreviewListener do
  @moduledoc """
  Supervised GenServer that subscribes to `"pipeline:events"` and enqueues
  `LinkPreviewWorker` jobs when messages containing URLs are persisted.

  Mirrors the pattern from `Slackex.Embeddings.PersistenceListener`.
  Only active when the `:link_previews` feature flag is enabled.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Slackex.Chat.Message
  alias Slackex.Links.{LinkPreviewWorker, URLExtractor}
  alias Slackex.Repo

  @pubsub Slackex.PubSub
  @topic "pipeline:events"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(_opts) do
    _ = Phoenix.PubSub.subscribe(@pubsub, @topic)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:messages_persisted, message_ids}, state) when is_list(message_ids) do
    if FunWithFlags.enabled?(:link_previews) do
      process_messages(message_ids)
    end

    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp process_messages(message_ids) do
    messages =
      from(m in Message,
        where: m.id in ^message_ids,
        where: is_nil(m.deleted_at)
      )
      |> Repo.all()

    Enum.each(messages, fn message ->
      urls = URLExtractor.extract(message.content)

      case LinkPreviewWorker.enqueue(message.id, urls) do
        {:ok, _job} ->
          Logger.info("LinkPreviewListener: enqueued preview for message #{message.id}")

        :noop ->
          :ok
      end
    end)
  end
end
