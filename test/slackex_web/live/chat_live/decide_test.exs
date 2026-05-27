defmodule SlackexWeb.ChatLive.DecideTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, :manual) end)

    # FunWithFlags state is shared (not sandboxed), so a test that disables
    # :sous would leak into siblings. Re-enable per test (setup runs before
    # each test since async: false) so order-independence holds.
    FunWithFlags.enable(:sous)

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

  test "/decide does nothing when the :sous flag is off", %{conn: conn, channel: channel} do
    FunWithFlags.disable(:sous)
    # Restore on exit so the disable never leaks to other test files (this is
    # the global flag store, not a per-test sandbox).
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    html =
      lv
      |> form("#message-form", %{message: %{content: "/decide"}})
      |> render_submit()

    refute html =~ "Capture a decision"
  end

  test "decision cards do not render when :sous is off", %{
    conn: conn,
    channel: channel,
    alice: alice
  } do
    # Create a carded decision while the flag is ON (setup state).
    {:ok, wi} =
      Slackex.Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: alice.id,
        actor_username: alice.username,
        title: "Hidden When Off",
        what: "secret",
        stakeholders: []
      })

    {:ok, _carded} = Slackex.Sous.post_decision_card(wi, alice.id)

    # Now turn the flag off and mount the channel.
    FunWithFlags.disable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    refute render(lv) =~ "lives in: In Service"
  end

  test "a posted decision renders as a card in the channel", %{conn: conn, channel: channel} do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    lv |> form("#message-form", %{message: %{content: "/decide"}}) |> render_submit()

    lv
    |> form("#decide-form", %{
      decision: %{title: "Visible Card", what: "the what", why: "", next: ""}
    })
    |> render_submit()

    assert render(lv) =~ "lives in: In Service"
    assert render(lv) =~ "the what"
    assert render(lv) =~ "DRI: alice"
  end
end
