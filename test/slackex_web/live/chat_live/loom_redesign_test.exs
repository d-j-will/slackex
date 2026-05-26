defmodule SlackexWeb.ChatLive.LoomRedesignTest do
  use SlackexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Slackex.TestFactory

  setup do
    on_exit(fn -> FunWithFlags.disable(:loom_redesign) end)
    :ok
  end

  test "chat root has no loom class when flag disabled", %{conn: conn} do
    FunWithFlags.disable(:loom_redesign)
    user = insert(:user)
    {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/chat")

    refute html |> Floki.parse_document!() |> Floki.find("#chat-container.loom") |> Enum.any?()
    assert html |> Floki.parse_document!() |> Floki.find("#chat-container") |> Enum.any?()
  end

  test "chat root has loom class when flag enabled for actor", %{conn: conn} do
    user = insert(:user)
    FunWithFlags.enable(:loom_redesign, for_actor: user)
    {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/chat")

    assert html |> Floki.parse_document!() |> Floki.find("#chat-container.loom") |> Enum.any?()
  end

  test "appearance trigger is hidden when loom is disabled", %{conn: conn} do
    FunWithFlags.disable(:loom_redesign)
    user = insert(:user)
    {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/chat")

    refute html =~ ~s(aria-label="Appearance")
  end

  test "appearance trigger opens the appearance panel when loom is enabled", %{conn: conn} do
    user = insert(:user)
    FunWithFlags.enable(:loom_redesign, for_actor: user)
    {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/chat")

    # Trigger present but panel not yet rendered.
    assert html =~ ~s(aria-label="Appearance")
    refute render(lv) =~ ~s(id="appearance-modal")

    html = lv |> element(~s(button[aria-label="Appearance"])) |> render_click()

    # Sectioned panel with pref controls scoped under .loom.
    assert html =~ ~s(id="appearance-modal")
    assert html =~ ~s(phx-hook="AppearancePanel")
    assert html =~ ~s(data-pref="density")
    assert html =~ ~s(data-pref="weave")
    assert html =~ ~s(data-pref="serif-ai")
    assert html =~ ~s(data-pref="accent")

    # Close returns to no panel.
    html = lv |> element(~s(#appearance-backdrop)) |> render_click()
    refute html =~ ~s(id="appearance-modal")
  end
end
