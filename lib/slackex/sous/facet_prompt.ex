defmodule Slackex.Sous.FacetPrompt do
  @moduledoc """
  Pure prompt-template generator for Sous Slice B2 facet text. Keyed by `viewer.id`.

  Bumping `@prompt_version` auto-stales all rows below the new version (see
  `WorkItemFacet.state/1`). Viewers are immutable in B1 (invariant #11) so a
  module-constant template is defensible; when role-management UI lands, this
  moves to a `Viewer.prompt_template` field (B-later, spec §13).
  """

  alias Slackex.Sous.{Decision, Viewer, WorkItem}

  @prompt_version 2

  @doc "Current prompt template version. Bumping invalidates older facets via `state/1`."
  @spec prompt_version() :: integer()
  def prompt_version, do: @prompt_version

  @system_message """
  You write one short paragraph (1-3 sentences, max ~200 chars) telling a specific role
  what THIS decision means for THEM, seen only through their focus areas.

  Rules:
  - Lead with the concern, trade-off, or risk this role uniquely cares about — not a
    summary of the decision and not whether it is a good idea. Each role gets a different
    paragraph; if yours reads like it could belong to any role, rewrite it.
  - Be candid and specific. No praise or cheerleading, no "smart/pragmatic win", no
    recommending whether to ship, and never name or address the decision's author.
  - Stay strictly on the decision's stated content. Invent no facts.
  - Output ONLY the paragraph: no preamble, no "Here is…", no quotation marks, no role
    label, no markdown, no bullets.
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

    Write the 1-3-sentence facet for the #{viewer.name}, foregrounding their focus areas
    and the one concern those areas raise about this decision.
    """
  end
end
