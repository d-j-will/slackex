defmodule SlackexWeb.Plugs.AnalyticsPlugTest do
  @moduledoc """
  Exercises AnalyticsPlug through the real endpoint pipeline.

  These tests deliberately dispatch via `get/2` (the full endpoint) rather
  than calling the plug with a hand-built conn: the plug runs in
  `endpoint.ex` *before* the router's `fetch_session`, so any test that
  pre-fetches the session (e.g. `init_test_session`) creates state the
  production pipeline never provides and masks ordering bugs
  (incident: slackex-cv6 — `get_session` without `fetch_session` crashed
  on every request while the old unit tests stayed green).
  """

  use SlackexWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Slackex.Analytics.Event
  alias Slackex.Repo

  setup do
    FunWithFlags.enable(:website_analytics)
    :ok
  end

  describe "through the endpoint" do
    test "sets an analytics session id and tracks a page view on an HTML 200 response",
         %{conn: conn} do
      {conn, log} =
        with_log(fn ->
          conn = get(conn, ~p"/")
          assert html_response(conn, 200)
          conn
        end)

      refute log =~ "AnalyticsPlug: crashed"

      session_id = get_session(conn, :analytics_session_id)
      assert is_binary(session_id)
      assert {:ok, _} = Ecto.UUID.cast(session_id)

      # Oban runs in :inline testing mode, so the tracked event is already
      # persisted — assert the full producer -> consumer outcome.
      assert %Event{event_type: "page_view"} =
               Repo.get_by(Event, session_id: session_id)
    end

    test "preserves the session id across requests", %{conn: conn} do
      conn = get(conn, ~p"/")
      first_id = get_session(conn, :analytics_session_id)
      assert is_binary(first_id)

      # ConnTest recycles cookies between requests on the same conn,
      # mirroring a returning browser.
      conn = get(conn, ~p"/")
      assert get_session(conn, :analytics_session_id) == first_id
    end

    test "does not track non-HTML responses", %{conn: conn} do
      conn = get(conn, ~p"/health")
      assert json_response(conn, 200)

      assert Repo.aggregate(Event, :count) == 0
    end

    test "is a no-op when :website_analytics is disabled", %{conn: conn} do
      FunWithFlags.disable(:website_analytics)

      conn = get(conn, ~p"/")
      assert html_response(conn, 200)

      refute get_session(conn, :analytics_session_id)
      assert Repo.aggregate(Event, :count) == 0
    end
  end
end
