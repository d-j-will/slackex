defmodule SlackexWeb.SousLive.InServiceB2IndicatorTest do
  @moduledoc """
  Task 10 — Board card stale indicator + :facet_generated broadcast forwarding.
  When the active viewer is set AND that viewer has a stale row for a work item,
  the card renders a subtle dot indicator. Generation clears the indicator.
  """

  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

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
        title: "Indicate me",
        what: "lens me",
        stakeholders: []
      })

    %{conn: log_in_user(conn, user), user: user, wi: wi}
  end

  test "active viewer with stale row -> dot indicator renders on the card",
       %{conn: conn, user: u, wi: wi} do
    # Seed a row + mark it stale by moving the work item (invariant #14).
    {:ok, _} =
      Sous.set_facet_text(wi.id, "cto", %{
        facet_text: "old",
        model: "stub",
        prompt_version: Slackex.Sous.FacetPrompt.prompt_version(),
        state_version: 0
      })

    {:ok, _} = Sous.move(wi.id, :order, u.id)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    render_click(lv, "select_viewer", %{"id" => "cto"})

    html = render(lv)
    assert html =~ ~s|data-stale-indicator="#{wi.id}"|
  end

  test "no active viewer -> no dot indicator even with stale rows", %{conn: conn, user: u, wi: wi} do
    {:ok, _} =
      Sous.set_facet_text(wi.id, "cto", %{
        facet_text: "old",
        model: "stub",
        prompt_version: Slackex.Sous.FacetPrompt.prompt_version(),
        state_version: 0
      })

    {:ok, _} = Sous.move(wi.id, :order, u.id)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    refute render(lv) =~ "data-stale-indicator"
  end

  test ":facet_generated broadcast clears the indicator for the active viewer",
       %{conn: conn, user: u, wi: wi} do
    {:ok, _} =
      Sous.set_facet_text(wi.id, "cto", %{
        facet_text: "old",
        model: "stub",
        prompt_version: Slackex.Sous.FacetPrompt.prompt_version(),
        state_version: 0
      })

    {:ok, _} = Sous.move(wi.id, :order, u.id)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    render_click(lv, "select_viewer", %{"id" => "cto"})

    assert render(lv) =~ ~s|data-stale-indicator="#{wi.id}"|

    # Now generate text for cto — clears facet_stale_at + broadcasts.
    {:ok, _} =
      Sous.set_facet_text(wi.id, "cto", %{
        facet_text: "new",
        model: "stub",
        prompt_version: Slackex.Sous.FacetPrompt.prompt_version(),
        state_version: 1
      })

    # Bridge to flush parent's mailbox via a synchronous event.
    render_click(lv, "select_viewer", %{"id" => "cto"})

    refute render(lv) =~ ~s|data-stale-indicator="#{wi.id}"|
    _ = u
  end

  test ":state_changed broadcast sets the indicator for the active viewer when row exists",
       %{conn: conn, user: u, wi: wi} do
    {:ok, _} =
      Sous.set_facet_text(wi.id, "cto", %{
        facet_text: "fresh",
        model: "stub",
        prompt_version: Slackex.Sous.FacetPrompt.prompt_version(),
        state_version: 0
      })

    {:ok, lv, _} = live(conn, ~p"/in-service")
    render_click(lv, "select_viewer", %{"id" => "cto"})

    refute render(lv) =~ "data-stale-indicator"

    # Move — broadcasts :state_changed and marks the row stale.
    {:ok, _} = Sous.move(wi.id, :order, u.id)

    # Synchronously flush by triggering an event.
    render_click(lv, "select_viewer", %{"id" => "cto"})

    assert render(lv) =~ ~s|data-stale-indicator="#{wi.id}"|
  end
end
