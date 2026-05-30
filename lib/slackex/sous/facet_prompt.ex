defmodule Slackex.Sous.FacetPrompt do
  @moduledoc """
  Pure prompt-template generator for Sous Slice B2 facet text. Keyed by `viewer.id`.

  Bumping `@prompt_version` auto-stales all rows below the new version (see
  `WorkItemFacet.state/1`). Viewers are immutable in B1 (invariant #11) so a
  module-constant template is defensible; when role-management UI lands, this
  moves to a `Viewer.prompt_template` field (B-later, spec §13).
  """

  alias Slackex.Sous.{Decision, Viewer, WorkItem}

  @prompt_version 1

  @doc "Current prompt template version. Bumping invalidates older facets via `state/1`."
  @spec prompt_version() :: integer()
  def prompt_version, do: @prompt_version

  @system_message """
  You produce a single short paragraph (1-3 sentences, max ~200 chars) that frames a
  decision from a specific role's point of view. Stay on the decision's actual content;
  do not invent facts. Plain prose, no markdown, no bullets.
  """

  @doc """
  Builds the message list for `LLMClient.complete/2`. Function head enforces the
  struct types; we omit a `@spec` because credo flags struct literals in specs
  and these schemas don't declare a `t/0` (project convention).
  """
  def build(%Viewer{} = viewer, %WorkItem{} = work_item, %Decision{} = decision) do
    [
      %{role: "system", content: @system_message},
      %{role: "user", content: user_message(viewer, work_item, decision)}
    ]
  end

  defp user_message(viewer, work_item, decision) do
    """
    You are reading as the #{viewer.name}. Focus areas: #{Enum.join(viewer.focus, ", ")}.
    Decision: #{decision.what}
    Why: #{decision.why}
    Next: #{decision.next}
    State: #{work_item.state}
    Title: #{work_item.title}

    Write the 1-3-sentence facet that the #{viewer.name} should see.
    """
  end
end
