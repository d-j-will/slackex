defmodule Mix.Tasks.Tenun.CleanupWebPushTokens do
  use Boundary, classify_to: Slackex.MixTasks
  @moduledoc "Delete all web_push device tokens (for rolling back push notifications)."
  @shortdoc "Delete all web_push device tokens"

  use Mix.Task

  import Ecto.Query

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    {deleted, _} =
      Slackex.Notifications.DeviceToken
      |> where([t], t.platform == "web_push")
      |> Slackex.Repo.delete_all()

    Mix.shell().info("Deleted #{deleted} web_push device tokens.")
  end
end
