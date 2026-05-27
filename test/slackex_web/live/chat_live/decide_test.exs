defmodule SlackexWeb.ChatLive.DecideTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, :manual) end)

    alice = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(alice.id, %{name: "deploys"})
    conn = log_in_user(conn, alice)
    %{conn: conn, alice: alice, channel: channel}
  end

  test "typing /decide opens the modal", %{conn: conn, channel: channel} do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    html =
      lv
      |> form("#message-form", %{message: %{content: "/decide"}})
      |> render_submit()

    assert html =~ "Capture a decision"
  end

  test "submitting the modal creates a work item and a decision card", %{
    conn: conn,
    channel: channel
  } do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    lv |> form("#message-form", %{message: %{content: "/decide"}}) |> render_submit()

    lv
    |> form("#decide-form", %{
      decision: %{title: "Adopt ES", what: "Use a log", why: "audit", next: "spike"}
    })
    |> render_submit()

    grouped = Sous.list_in_flight()
    assert Enum.any?(grouped[:mise], &(&1.title == "Adopt ES"))
  end

  test "submitting with a blank What re-renders the modal with an error", %{
    conn: conn,
    channel: channel
  } do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    lv |> form("#message-form", %{message: %{content: "/decide"}}) |> render_submit()

    html =
      lv
      |> form("#decide-form", %{decision: %{title: "No what", what: "", why: "", next: ""}})
      |> render_submit()

    assert html =~ "Title and What are required."
    assert Sous.list_in_flight()[:mise] == []
  end
end
