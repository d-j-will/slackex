defmodule SlackexWeb.Plugs.AnalyticsPlugTest do
  use SlackexWeb.ConnCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias SlackexWeb.Plugs.AnalyticsPlug

  setup do
    FunWithFlags.enable(:website_analytics)
    on_exit(fn -> FunWithFlags.disable(:website_analytics) end)
    :ok
  end

  describe "call/2" do
    test "generates session_id when none exists" do
      conn =
        build_conn(:get, "/chat")
        |> init_test_session(%{})
        |> AnalyticsPlug.call(AnalyticsPlug.init([]))

      session_id = get_session(conn, :analytics_session_id)
      assert is_binary(session_id)
      assert String.length(session_id) == 36
    end

    test "preserves existing session_id" do
      existing_id = Ecto.UUID.generate()

      conn =
        build_conn(:get, "/chat")
        |> init_test_session(%{analytics_session_id: existing_id})
        |> AnalyticsPlug.call(AnalyticsPlug.init([]))

      assert get_session(conn, :analytics_session_id) == existing_id
    end

    test "is a no-op when :website_analytics flag is disabled" do
      FunWithFlags.disable(:website_analytics)

      conn =
        build_conn(:get, "/chat")
        |> init_test_session(%{})
        |> AnalyticsPlug.call(AnalyticsPlug.init([]))

      refute get_session(conn, :analytics_session_id)
    end
  end
end
