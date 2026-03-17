defmodule Slackex.Links do
  @moduledoc "Context module for link preview operations."

  use Boundary,
    deps: [Slackex.Chat],
    exports: [LinkPreview, LinkPreviewListener, URLExtractor]

  import Ecto.Query

  alias Slackex.Links.LinkPreview
  alias Slackex.Repo

  @doc "Returns a map of message_id => [%LinkPreview{}] for fetched previews."
  @spec list_previews_for_messages([integer()]) :: %{integer() => [LinkPreview.t()]}
  def list_previews_for_messages([]), do: %{}

  def list_previews_for_messages(message_ids) do
    from(lp in LinkPreview,
      where: lp.message_id in ^message_ids,
      where: lp.status in ["fetched", "pending"],
      order_by: [asc: lp.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.message_id)
  end
end
