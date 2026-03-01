defmodule Slackex.Release do
  @moduledoc """
  Tasks that can be run without Mix installed (i.e. in production releases).

  Usage:

      /app/bin/slackex eval "Slackex.Release.migrate()"
      /app/bin/slackex eval "Slackex.Release.rollback(Slackex.Repo, 20240101000000)"
  """

  @app :slackex

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
