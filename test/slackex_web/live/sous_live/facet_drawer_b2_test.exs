defmodule SlackexWeb.SousLive.FacetDrawerB2Test do
  @moduledoc """
  Task 9 — Facet Drawer B2 contract: lazy enqueue on open + 5 pill states +
  PubSub-driven refresh + manual retry path.

  Exercises the real LV entry point (`live(conn, ~p"/in-service")` +
  `render_click` on the board card). Oban runs `:inline` in tests, so the
  worker completes inside `render_click` and the LV receives the PubSub
  broadcast — end-state assertions (row populated, `:fresh` rendered) are
  the right shape here.
  """

  use SlackexWeb.ConnCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Slackex.Repo
  alias Slackex.Sous
  alias Slackex.Sous.WorkItemFacet

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    # OpentelemetryOban's :oban.job.start handler crashes on inline-mode jobs
    # whose scheduled_at is nil. We detach it for this suite — these tests don't
    # care about traces, and reattaching is the application's job at boot.
    _ = :telemetry.detach("Elixir.OpentelemetryOban.JobHandler.job_start")
    _ = :telemetry.detach("Elixir.OpentelemetryOban.JobHandler.job_stop")
    _ = :telemetry.detach("Elixir.OpentelemetryOban.JobHandler.job_exception")

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

    user = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "B2 drawer",
        what: "lens this",
        why: "the why",
        next: "the next",
        stakeholders: []
      })

    %{conn: log_in_user(conn, user), user: user, wi: wi}
  end

  defp flush_lv(lv), do: render_hook(lv, "viewer_pref:loaded", %{"viewer_id" => nil})

  defp configure!, do: Application.put_env(:slackex, :llm_api, %{api_key: "stub"})
  defp unconfigure!, do: Application.delete_env(:slackex, :llm_api)

  describe "lazy-on-open enqueue" do
    test "with LLM configured + no facets -> jobs enqueued and rows populated for every viewer",
         %{conn: conn, wi: wi} do
      configure!()
      viewer_count = length(Sous.list_viewers())

      {:ok, lv, _} = live(conn, ~p"/in-service")
      lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()
      flush_lv(lv)

      # Oban runs :inline in test — jobs complete inside `Oban.insert/1` and
      # are NOT persisted to oban_jobs. End-state check: every viewer has a
      # :facet_generated event (proves the worker ran for each).
      viewers_with_events =
        Repo.all(
          from e in Slackex.Sous.WorkItemEvent,
            where: e.work_item_id == ^wi.id and e.type == :facet_generated,
            select: fragment("?->>'viewer_id'", e.payload)
        )

      assert MapSet.new(viewers_with_events) ==
               MapSet.new(Enum.map(Sous.list_viewers(), & &1.id))

      # Inline mode: jobs complete within render_click -> rows populated.
      rows = Sous.facets_for_work_item(wi.id)
      assert length(rows) == viewer_count

      for r <- rows do
        assert r.facet_text != nil
        assert r.facet_text =~ "[stub:"
      end

      # And the drawer shows the facet text (at least the CTO prism).
      html = render(lv)
      assert html =~ "[stub:CTO]"
    end

    test "with LLM not configured -> no jobs run, 'AI text unavailable' rendered",
         %{conn: conn, wi: wi} do
      unconfigure!()

      {:ok, lv, _} = live(conn, ~p"/in-service")
      lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

      # Inline mode: if a job had been inserted it would have run and written
      # an event. Absence of :facet_generated events proves no enqueue happened.
      events =
        Repo.all(
          from e in Slackex.Sous.WorkItemEvent,
            where: e.work_item_id == ^wi.id and e.type == :facet_generated
        )

      assert events == []
      assert render(lv) =~ "AI text unavailable"
    end

    test "with all-fresh rows -> 0 jobs enqueued; facet text rendered", %{conn: conn, wi: wi} do
      configure!()

      for v <- Sous.list_viewers() do
        {:ok, _} =
          Sous.set_facet_text(wi.id, v.id, %{
            facet_text: "pre-existing",
            model: "stub",
            prompt_version: 1,
            state_version: 0
          })
      end

      events_before =
        Repo.aggregate(
          from(e in Slackex.Sous.WorkItemEvent,
            where: e.work_item_id == ^wi.id and e.type == :facet_generated
          ),
          :count
        )

      {:ok, lv, _} = live(conn, ~p"/in-service")
      lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

      events_after =
        Repo.aggregate(
          from(e in Slackex.Sous.WorkItemEvent,
            where: e.work_item_id == ^wi.id and e.type == :facet_generated
          ),
          :count
        )

      # No new :facet_generated events since all viewers were already fresh.
      assert events_before == events_after
      assert render(lv) =~ "pre-existing"
    end

    test "with stale rows (after :state_changed) -> jobs re-enqueued and rows refreshed",
         %{conn: conn, user: u, wi: wi} do
      configure!()

      # Pre-populate then move; B2 invariant #14 marks rows stale (without enqueuing).
      for v <- Sous.list_viewers() do
        {:ok, _} =
          Sous.set_facet_text(wi.id, v.id, %{
            facet_text: "old",
            model: "stub",
            prompt_version: 1,
            state_version: 0
          })
      end

      {:ok, _} = Sous.move(wi.id, :order, u.id)
      stale_row = Repo.get_by!(WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")
      refute is_nil(stale_row.facet_stale_at)

      {:ok, lv, _} = live(conn, ~p"/in-service")
      lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()
      flush_lv(lv)

      # Inline mode doesn't persist jobs — jobs run synchronously inside insert.
      # End-state check: the :facet_generated event for CTO at state_version=1
      # was written, the row text changed, and facet_stale_at was cleared.
      cto_facet_state_versions =
        Repo.all(
          from e in Slackex.Sous.WorkItemEvent,
            where: e.work_item_id == ^wi.id and e.type == :facet_generated,
            select: fragment("(?->>'state_version')::int", e.payload)
        )

      assert 1 in cto_facet_state_versions

      refreshed = Repo.get_by!(WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")
      assert refreshed.facet_stale_at == nil
      refute refreshed.facet_text == "old"
    end
  end

  describe ":failed pill + retry path" do
    test "discarded Oban job -> :failed pill renders retry glyph; click re-enqueues",
         %{conn: conn, wi: wi} do
      configure!()

      # Persist a discarded job for CTO so the drawer picks it up at open.
      # Bypass Oban.insert (which doesn't accept a state opt) — go straight to Repo.
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.insert!(%Oban.Job{
        worker: "Slackex.Sous.FacetWorker",
        queue: "facets",
        args: %{
          "work_item_id" => wi.id,
          "viewer_id" => "cto",
          "prompt_version" => 1,
          "state_version" => 0
        },
        state: "discarded",
        max_attempts: 3,
        attempt: 3,
        attempted_at: now,
        discarded_at: now,
        inserted_at: now,
        scheduled_at: now
      })

      {:ok, lv, _} = live(conn, ~p"/in-service")
      lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

      html = render(lv)
      # CTO is :failed; all other viewers will be :fresh (auto-enqueue ran for them).
      assert html =~ ~s|data-facet-state="failed"|
      assert html =~ "retry"

      # Click the retry glyph for CTO.
      lv
      |> element(~s{[data-prism-text="cto"] button[phx-click="retry_facet"]})
      |> render_click()

      flush_lv(lv)

      # Either inline-completed (row populated for cto) or still enqueued.
      row = Repo.get_by!(WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")
      assert is_binary(row.facet_text)
    end
  end

  describe "B1 attention pill gesture (no regression)" do
    test "clicking the act pill on the CTO prism sets :attention_set", %{conn: conn, wi: wi} do
      configure!()

      {:ok, lv, _} = live(conn, ~p"/in-service")
      lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

      lv
      |> element(~s{[data-prism="cto"] button[phx-value-attention="act"]})
      |> render_click()

      flush_lv(lv)

      facet = Repo.get_by!(WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")
      assert facet.attention == :act
    end
  end
end
