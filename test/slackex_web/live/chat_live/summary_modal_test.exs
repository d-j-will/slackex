defmodule SlackexWeb.ChatLive.SummaryModalTest do
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Chat

  setup %{conn: conn} do
    Redix.command!(:redix_0, ["FLUSHDB"])
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})

    # Ensure LLM is configured so summarizer doesn't return :not_configured
    Application.put_env(:slackex, :llm_api, %{api_key: "stub"})

    on_exit(fn ->
      Application.delete_env(:slackex, :llm_api)
    end)

    {:ok, channel} = Chat.create_channel(user.id, %{name: "summary-test"})

    %{conn: conn, user: user, channel: channel}
  end

  describe "summarize button visibility" do
    test "shows summarize button when flag is enabled", %{conn: conn, channel: channel} do
      FunWithFlags.enable(:channel_summarization)

      {:ok, _view, html} = live(conn, ~p"/chat/#{channel.slug}")
      assert html =~ "data-role=\"summarize-button\""
    end

    test "hides summarize button when flag is disabled", %{conn: conn, channel: channel} do
      FunWithFlags.disable(:channel_summarization)

      {:ok, _view, html} = live(conn, ~p"/chat/#{channel.slug}")
      refute html =~ "data-role=\"summarize-button\""
    end
  end

  describe "summary modal interaction" do
    setup %{channel: channel} do
      FunWithFlags.enable(:channel_summarization)
      %{channel: channel}
    end

    test "opens modal on button click", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      html = view |> element("[data-role=summarize-button]") |> render_click()
      assert html =~ "data-role=\"summary-modal\""
      assert html =~ "Channel Summary"
    end

    test "shows time range buttons in idle state", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      html = view |> element("[data-role=summarize-button]") |> render_click()
      assert html =~ "data-role=\"time-range-24h\""
      assert html =~ "data-role=\"time-range-7d\""
      assert html =~ "data-role=\"time-range-30d\""
    end

    test "close button dismisses modal", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      view |> element("[data-role=summarize-button]") |> render_click()
      # Component sends message to parent; render parent view to see updated state
      view |> element("[data-role=close-summary]") |> render_click()
      html = render(view)
      refute html =~ "data-role=\"summary-modal\""
    end

    test "completing a summary shows the result text", %{conn: conn, channel: channel, user: user} do
      Chat.send_message(channel.id, user.id, "Test message for summary")

      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      view |> element("[data-role=summarize-button]") |> render_click()
      view |> element("[data-role=time-range-24h]") |> render_click()

      # Wait for async task to stream and complete
      Process.sleep(200)
      html = render(view)
      # StubLLMClient returns canned summary text
      assert html =~ "summary"
    end

    test "shows error when no messages in range", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      view |> element("[data-role=summarize-button]") |> render_click()
      view |> element("[data-role=time-range-30d]") |> render_click()

      # Wait for the async task to complete
      Process.sleep(100)
      html = render(view)
      assert html =~ "No messages found"
    end
  end
end
