defmodule SlackexWeb.AdminLive.AnalyticsTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    FunWithFlags.enable(:website_analytics)
    :ok
  end

  defp auth_admin(conn) do
    config = Application.fetch_env!(:slackex, :flags_admin_auth)
    credentials = Base.encode64("#{config[:username]}:#{config[:password]}")

    conn
    |> init_test_session(%{})
    |> put_req_header("authorization", "Basic #{credentials}")
  end

  describe "overview tab" do
    test "renders analytics overview when flag is enabled", %{conn: conn} do
      conn = auth_admin(conn)
      {:ok, _view, html} = live(conn, "/admin/analytics")

      assert html =~ "Analytics"
      assert html =~ "Active Users"
    end

    test "shows disabled message when flag is off", %{conn: conn} do
      FunWithFlags.disable(:website_analytics)
      conn = auth_admin(conn)
      {:ok, _view, html} = live(conn, "/admin/analytics")

      assert html =~ "Analytics disabled"
    end
  end
end
