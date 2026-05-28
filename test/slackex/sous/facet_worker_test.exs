defmodule Slackex.Sous.FacetWorkerTest do
  @moduledoc """
  Unit tests for the FacetWorker. Covers:

    * configured-stub path -> row populated, event written
    * not-configured path -> {:discard, :llm_not_configured} + warning logged
    * missing dependency path -> {:discard, :missing_dependency} + warning
    * LLM error -> {:error, reason} (Oban retries) + warning
    * state_version from args is persisted unchanged (worker contract)
    * Oban uniqueness collapses duplicate enqueues to one event

  Failure-visibility through-retry (capture_log + 3 attempts) lives in Task 12.
  """

  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  import ExUnit.CaptureLog

  alias Slackex.Repo
  alias Slackex.Sous
  alias Slackex.Sous.{FacetWorker, WorkItemEvent, WorkItemFacet}

  setup do
    # `:llm_api` controls LLMClient.configured?/0 globally. Snapshot/restore.
    prior_api = Application.get_env(:slackex, :llm_api)
    prior_client = Application.get_env(:slackex, :llm_client)
    Application.put_env(:slackex, :llm_api, %{api_key: "stub"})
    Application.put_env(:slackex, :llm_client, Slackex.AI.StubLLMClient)

    on_exit(fn ->
      if is_nil(prior_api),
        do: Application.delete_env(:slackex, :llm_api),
        else: Application.put_env(:slackex, :llm_api, prior_api)

      if is_nil(prior_client),
        do: Application.delete_env(:slackex, :llm_client),
        else: Application.put_env(:slackex, :llm_client, prior_client)
    end)

    user = insert(:user)
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "B2 worker",
        what: "facet text via worker",
        stakeholders: []
      })

    %{user: user, wi: wi}
  end

  defp args(wi_id, viewer_id, prompt_v \\ 1, state_v \\ 0) do
    %{
      "work_item_id" => wi_id,
      "viewer_id" => viewer_id,
      "prompt_version" => prompt_v,
      "state_version" => state_v
    }
  end

  test "configured stub + valid args -> :ok, row populated, event written", %{wi: wi} do
    assert {:ok, _} = perform_job(FacetWorker, args(wi.id, "cto"))

    row = Repo.get_by!(WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")
    assert row.facet_text =~ "CTO"
    assert row.facet_prompt_version == 1
    assert row.attention == :watch

    [event] = Repo.all(from e in WorkItemEvent, where: e.type == :facet_generated)
    assert event.payload["viewer_id"] == "cto"
    assert event.payload["state_version"] == 0
  end

  test "LLMClient not configured -> {:discard, :llm_not_configured} + warning", %{wi: wi} do
    Application.delete_env(:slackex, :llm_api)

    log =
      capture_log(fn ->
        assert {:discard, :llm_not_configured} = perform_job(FacetWorker, args(wi.id, "cto"))
      end)

    assert log =~ "LLMClient not configured"

    assert Repo.aggregate(from(e in WorkItemEvent, where: e.type == :facet_generated), :count) ==
             0
  end

  test "missing work item -> {:discard, :missing_dependency} + warning" do
    log =
      capture_log(fn ->
        assert {:discard, :missing_dependency} =
                 perform_job(FacetWorker, args(999_999_999, "cto"))
      end)

    assert log =~ "missing dependency"
  end

  test "missing viewer -> {:discard, :missing_dependency}", %{wi: wi} do
    assert {:discard, :missing_dependency} =
             perform_job(FacetWorker, args(wi.id, "no-such-viewer"))
  end

  test "LLM client returns {:error, _} -> {:error, _} + warning", %{wi: wi} do
    Application.put_env(:slackex, :llm_client, Slackex.Sous.FacetWorkerTest.ErrorClient)

    log =
      capture_log(fn ->
        assert {:error, :nope} = perform_job(FacetWorker, args(wi.id, "cto"))
      end)

    assert log =~ "LLM call failed"
  end

  test "worker writes state_version from args unchanged, even if Sous.state_version/1 has changed",
       %{user: u, wi: wi} do
    # Simulate: drawer enqueues at state_version 0, then :state_changed bumps it to 1,
    # then the worker runs. The worker MUST persist 0 (the value from args).
    {:ok, _} = Sous.move(wi.id, :order, u.id)
    assert Sous.state_version(wi.id) == 1

    assert {:ok, _} = perform_job(FacetWorker, args(wi.id, "cto", 1, 0))

    [event] = Repo.all(from e in WorkItemEvent, where: e.type == :facet_generated)
    assert event.payload["state_version"] == 0
  end

  test "duplicate enqueue with identical args collapses to one event (Oban uniqueness)",
       %{wi: wi} do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _job1} = Oban.insert(FacetWorker.new(args(wi.id, "cto")))
      {:ok, job2} = Oban.insert(FacetWorker.new(args(wi.id, "cto")))

      # Oban returns the original job with conflict? = true; only ONE row is
      # persisted in oban_jobs for these args.
      assert job2.conflict? == true

      %{success: 1} = Oban.drain_queue(queue: :facets, with_recursion: true)
    end)

    events = Repo.all(from e in WorkItemEvent, where: e.type == :facet_generated)
    assert length(events) == 1
  end

  defmodule ErrorClient do
    @moduledoc false
    @behaviour Slackex.AI.LLMClient
    @impl true
    def complete(_messages, _opts), do: {:error, :nope}
    @impl true
    def stream(_messages, _opts), do: {:error, :nope}
  end
end
