defmodule Slackex.Links.LinkPreviewWorker do
  @moduledoc """
  Oban worker that fetches link preview metadata for URLs in messages.

  Pipeline per URL:
  1. Check domain blocklist + Google Safe Browsing
  2. Fetch page and parse OpenGraph metadata (2s timeout)
  3. Insert link_preview record
  4. Broadcast via PubSub

  Any fetch failure results in a blocked preview — if a URL can't load
  fast and clean, it doesn't get a preview.
  """

  use Oban.Worker,
    queue: :link_previews,
    max_attempts: 1,
    unique: [fields: [:args], keys: [:message_id], period: 60]

  require Logger

  alias Slackex.Links.{LinkPreview, MetadataParser, SafetyChecker}
  alias Slackex.Repo

  @pubsub Slackex.PubSub

  @doc "Enqueues a link preview job for a message with extracted URLs."
  @spec enqueue(integer(), [String.t()]) :: {:ok, Oban.Job.t()} | :noop
  def enqueue(_message_id, []), do: :noop

  def enqueue(message_id, urls) when is_list(urls) do
    %{message_id: message_id, urls: urls}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id, "urls" => urls}}) do
    previews = Enum.map(urls, &process_url(message_id, &1))

    fetched = Enum.filter(previews, &(&1.status == "fetched"))

    _ =
      if fetched != [] do
        broadcast_previews(message_id, fetched)
      end

    :ok
  end

  defp process_url(message_id, url) do
    case SafetyChecker.check(url) do
      {:blocked, reason} ->
        insert_preview(message_id, url, %{status: "blocked", blocked_reason: reason})

      :ok ->
        fetch_and_store(message_id, url)
    end
  end

  defp fetch_and_store(message_id, url) do
    case MetadataParser.fetch_and_parse(url) do
      {:ok, %{title: nil}} ->
        insert_preview(message_id, url, %{status: "blocked", blocked_reason: "fetch_error"})

      {:ok, metadata} ->
        insert_preview(message_id, url, Map.put(metadata, :status, "fetched"))

      {:error, _reason} ->
        insert_preview(message_id, url, %{status: "blocked", blocked_reason: "fetch_error"})
    end
  end

  defp insert_preview(message_id, url, attrs) do
    changeset =
      %LinkPreview{}
      |> LinkPreview.changeset(Map.merge(attrs, %{message_id: message_id, url: url}))

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:message_id, :url]
         ) do
      {:ok, %LinkPreview{id: nil}} ->
        Repo.get_by!(LinkPreview, message_id: message_id, url: url)

      {:ok, preview} ->
        preview
    end
  end

  defp broadcast_previews(message_id, previews) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "link_previews:#{message_id}",
      {:link_previews_ready, message_id, previews}
    )
  end
end
