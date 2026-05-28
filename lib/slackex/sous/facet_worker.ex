defmodule Slackex.Sous.FacetWorker do
  @moduledoc """
  Generates per-(work_item, viewer) facet text — the **only** LLM caller in Sous
  (invariant #17). Fired by drawer-open auto-enqueue or manual retry of `:failed`
  in the Facet Drawer; never by `:state_changed` (invariant #14).

  Reads `state_version` from `job.args` and passes it through to the event
  payload **unchanged**. Re-querying `Sous.state_version/1` here would silently
  break Oban's uniqueness contract (the uniqueness key is hashed over args at
  enqueue time, and a worker that writes a different state_version than it was
  enqueued with would defeat dedup).
  """

  use Oban.Worker,
    queue: :facets,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:work_item_id, :viewer_id, :prompt_version, :state_version]
    ]

  alias Slackex.AI.LLMClient
  alias Slackex.Sous
  alias Slackex.Sous.FacetPrompt

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "work_item_id" => work_item_id,
          "viewer_id" => viewer_id,
          "prompt_version" => prompt_version,
          "state_version" => state_version
        }
      }) do
    if LLMClient.configured?() do
      run_with_dependencies(work_item_id, viewer_id, prompt_version, state_version)
    else
      Logger.warning(
        "FacetWorker: LLMClient not configured; discarding job " <>
          "work_item_id=#{inspect(work_item_id)} viewer_id=#{inspect(viewer_id)}"
      )

      {:discard, :llm_not_configured}
    end
  end

  defp run_with_dependencies(work_item_id, viewer_id, prompt_version, state_version) do
    viewer = Sous.get_viewer(viewer_id)
    work_item = Sous.get_work_item(work_item_id)
    decision = Sous.get_decision(work_item_id)

    if is_nil(viewer) or is_nil(work_item) or is_nil(decision) do
      Logger.warning(
        "FacetWorker: missing dependency; discarding " <>
          "work_item_id=#{inspect(work_item_id)} viewer_id=#{inspect(viewer_id)}"
      )

      {:discard, :missing_dependency}
    else
      call_llm_and_persist(
        viewer,
        work_item,
        decision,
        prompt_version,
        state_version,
        work_item_id,
        viewer_id
      )
    end
  end

  defp call_llm_and_persist(
         viewer,
         work_item,
         decision,
         prompt_version,
         state_version,
         work_item_id,
         viewer_id
       ) do
    messages = FacetPrompt.build(viewer, work_item, decision)
    model = Application.get_env(:slackex, :llm_facet_model)

    opts =
      [purpose: :sous_facet, max_tokens: 200]
      |> maybe_put(:model, model)

    case LLMClient.complete(messages, opts) do
      {:ok, text} ->
        Sous.set_facet_text(work_item_id, viewer_id, %{
          facet_text: text,
          model: model,
          prompt_version: prompt_version,
          state_version: state_version
        })

      {:error, reason} ->
        Logger.warning(
          "FacetWorker: LLM call failed; will retry " <>
            "work_item_id=#{inspect(work_item_id)} viewer_id=#{inspect(viewer_id)} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
