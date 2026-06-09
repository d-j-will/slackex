defmodule Mix.Tasks.Slackex.BackfillEmbeddings do
  use Boundary, classify_to: Slackex.MixTasks

  @moduledoc """
  Backfills vector embeddings for all existing messages.

  Delegates to `Slackex.Release.backfill_embeddings/1` which is also
  available in production releases via `bin/slackex eval`.

  ## Usage

      mix slackex.backfill_embeddings           # only messages missing embeddings
      mix slackex.backfill_embeddings --force    # delete all embeddings first, then re-embed
  """

  use Mix.Task

  @shortdoc "Backfill embeddings for all existing messages"
  def run(args) do
    opts = if "--force" in args, do: [force: true], else: []
    Slackex.Release.backfill_embeddings(opts)
  end
end
