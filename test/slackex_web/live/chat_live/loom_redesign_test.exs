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
end
