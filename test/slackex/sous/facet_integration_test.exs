defmodule Slackex.Sous.FacetIntegrationTest do
  @moduledoc """
  Mandatory cross-context integration tests for Sous Slice B2 (spec §9 +
  CLAUDE.md "Spec-Driven Acceptance Tests"). Each test exercises the FULL
  producer -> consumer path through the REAL LiveView entry point:

    live(conn, ~p"/in-service")
      |> element("[phx-click='open_drawer']...")
      |> render_click()

  No hand-crafted assigns, no upstream-faking. A failure here means real
  wiring drift (drawer-mount enqueue path, Projection clause, broadcast
  topic, etc.), not just a handler bug.
  """

  use SlackexWeb.ConnCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Slackex.Repo
  alias Slackex.Sous
  alias Slackex.Sous.{FacetWorker, WorkItemEvent, WorkItemFacet}

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)

    prior_api = Application.get_env(:slackex, :llm_api)
    prior_client = Application.get_env(:slackex, :llm_client)

    on_exit(fn ->
      if is_nil(prior_api),
        do: Application.delete_env(:slackex, :llm_api),
        else: Application.put_env(:slackex, :llm_api, prior_api)

      if is_nil(prior_client),
        do: Application.delete_env(:slackex, :llm_client),
        else: Application.put_env(:slackex, :llm_client, prior_client)
    end)

    Application.put_env(:slackex, :llm_client, Slackex.AI.StubLLMClient)

    # Detach OpentelemetryOban telemetry — its job_start handler chokes on
    # nil :scheduled_at in inline mode and the failure bubbles up through
    # render_click. Tests don't care about traces.
    _ = :telemetry.detach("Elixir.OpentelemetryOban.JobHandler.job_start")
    _ = :telemetry.detach("Elixir.OpentelemetryOban.JobHandler.job_stop")
    _ = :telemetry.detach("Elixir.OpentelemetryOban.JobHandler.job_exception")

    user = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "B2 integration",
        what: "lens this",
        why: "the why",
        next: "the next",
        stakeholders: []
      })

    %{conn: log_in_user(conn, user), user: user, wi: wi}
  end

  test "WIRING: drawer-click -> FacetWorker -> :facet_generated event -> projection has text",
       %{conn: conn, wi: wi} do
    Application.put_env(:slackex, :llm_api, %{api_key: "stub"})

    {:ok, lv, _} = live(conn, ~p"/in-service")
    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

    # Inline mode: jobs run synchronously inside `Oban.insert`. The proof of
    # wiring is at both ends of the pipe — the event log has an entry for each
    # viewer (worker called set_facet_text) AND the projection materialised
    # rows for each viewer (Projection clause + Multi upsert).
    viewer_count = length(Sous.list_viewers())

    events =
      Repo.all(
        from e in WorkItemEvent,
          where: e.work_item_id == ^wi.id and e.type == :facet_generated
      )

    assert length(events) == viewer_count, "expected one :facet_generated event per viewer"

    rows = Sous.facets_for_work_item(wi.id)
    assert length(rows) == viewer_count

    for r <- rows do
      assert is_binary(r.facet_text), "row for #{r.viewer_id} has no facet_text"
      assert r.facet_text =~ "[stub:"
      assert r.facet_stale_at == nil
      # Invariant #16: lazy default attention :watch on the generated row
      # (no :attention_set event was issued).
      assert r.attention == :watch
    end
  end

  test "INVALIDATION: Sous.move/3 marks facet_stale_at + does NOT enqueue (invariant #14)",
       %{conn: conn, user: u, wi: wi} do
    Application.put_env(:slackex, :llm_api, %{api_key: "stub"})

    # First populate facets via drawer-open (wiring path).
    {:ok, lv, _} = live(conn, ~p"/in-service")
    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

    viewer_count = length(Sous.list_viewers())

    rows_before = Sous.facets_for_work_item(wi.id)
    assert length(rows_before) == viewer_count

    events_before =
      Repo.aggregate(
        from(e in WorkItemEvent,
          where: e.work_item_id == ^wi.id and e.type == :facet_generated
        ),
        :count
      )

    # Close drawer to break the subscription so we don't auto-re-enqueue on
    # the next broadcast.
    _ = render_hook(lv, "viewer_pref:loaded", %{"viewer_id" => nil})

    {:ok, _} = Sous.move(wi.id, :order, u.id)

    # The move marked every row stale.
    rows_after = Sous.facets_for_work_item(wi.id)

    for r <- rows_after do
      assert %DateTime{} = r.facet_stale_at,
             "expected stale_at on every existing row after move"
    end

    # And it did NOT produce more :facet_generated events (invariant #14).
    events_after =
      Repo.aggregate(
        from(e in WorkItemEvent,
          where: e.work_item_id == ^wi.id and e.type == :facet_generated
        ),
        :count
      )

    assert events_after == events_before
  end

  test "IDEMPOTENCY: two manual inserts with identical (wi, viewer, prompt_v, state_v) collapse to one event",
       %{wi: wi} do
    Application.put_env(:slackex, :llm_api, %{api_key: "stub"})

    args = %{
      "work_item_id" => wi.id,
      "viewer_id" => "cto",
      "prompt_version" => 1,
      "state_version" => 0
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _job1} = Oban.insert(FacetWorker.new(args))
      {:ok, job2} = Oban.insert(FacetWorker.new(args))
      assert job2.conflict?

      %{success: 1} = Oban.drain_queue(queue: :facets, with_recursion: true)
    end)

    events =
      Repo.all(from e in WorkItemEvent, where: e.type == :facet_generated)

    assert length(events) == 1
  end

  test "GRACEFUL DEGRADE: configured?/0 false -> Drawer says 'AI text unavailable'; no events",
       %{conn: conn, wi: wi} do
    Application.delete_env(:slackex, :llm_api)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

    assert render(lv) =~ "AI text unavailable"

    events =
      Repo.all(
        from e in WorkItemEvent,
          where: e.work_item_id == ^wi.id and e.type == :facet_generated
      )

    assert events == []

    rows = Repo.all(from f in WorkItemFacet, where: f.work_item_id == ^wi.id)
    assert rows == []
  end
end
