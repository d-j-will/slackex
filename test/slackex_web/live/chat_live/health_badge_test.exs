defmodule SlackexWeb.ChatLive.HealthBadgeTest do
  use SlackexWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slackex.TestFactory

  alias Slackex.Notifications.DeviceToken
  alias Slackex.Repo

  @subscription_json ~s({"endpoint":"https://fcm.googleapis.com/fcm/send/abc","keys":{"p256dh":"x","auth":"y"}})

  setup do
    Redix.command!(:redix_0, ["FLUSHDB"])
    :ok
  end

  test "renders :not_set_up health when permission is default", %{conn: conn} do
    user = insert(:user)
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, ~p"/chat")

    render_hook(view, "push:status", %{
      "permission" => "default",
      "subscribed" => false,
      "subscription" => nil
    })

    html = render(view)
    assert html =~ ~s(data-push-health="not_set_up")
  end

  test "renders :browser_blocked when permission is denied", %{conn: conn} do
    user = insert(:user)
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, ~p"/chat")

    render_hook(view, "push:status", %{
      "permission" => "denied",
      "subscribed" => false,
      "subscription" => nil
    })

    assert render(view) =~ ~s(data-push-health="browser_blocked")
  end

  test "renders :ok when permission granted, subscribed, and a token row exists",
       %{conn: conn} do
    user = insert(:user)
    insert(:device_token, user: user, token: @subscription_json, platform: "web_push")

    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, ~p"/chat")

    render_hook(view, "push:status", %{
      "permission" => "granted",
      "subscribed" => true,
      "subscription" => @subscription_json
    })

    # Verify the row still exists (auto-heal didn't delete it)
    assert Repo.exists?(from dt in DeviceToken, where: dt.user_id == ^user.id)
    # The sidebar icon is hidden when :ok (no element rendered), so refute both non-ok states:
    refute render(view) =~ ~s(data-push-health="not_set_up")
    refute render(view) =~ ~s(data-push-health="browser_blocked")
  end
end
