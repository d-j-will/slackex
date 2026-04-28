defmodule SlackexWeb.ChatLive.PushStatusAutohealTest do
  use SlackexWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slackex.TestFactory

  alias Slackex.Notifications.DeviceToken
  alias Slackex.Repo

  @subscription_json """
  {"endpoint":"https://fcm.googleapis.com/fcm/send/abc123","keys":{"p256dh":"BFooBar","auth":"BarFoo"}}
  """

  setup do
    Redix.command!(:redix_0, ["FLUSHDB"])
    :ok
  end

  test "push:status auto-heals a missing DeviceToken when browser still holds the subscription",
       %{conn: conn} do
    user = insert(:user)
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, ~p"/chat")

    # Pre-condition: no token rows for this user
    assert Repo.all(from(dt in DeviceToken, where: dt.user_id == ^user.id)) == []

    # Hook reports the browser-side subscription on every status check
    render_hook(view, "push:status", %{
      "permission" => "granted",
      "subscribed" => true,
      "subscription" => String.trim(@subscription_json)
    })

    [token] = Repo.all(from(dt in DeviceToken, where: dt.user_id == ^user.id))
    assert token.token == String.trim(@subscription_json)
    assert token.platform == "web_push"
  end

  test "push:status does not duplicate the row on subsequent checks", %{conn: conn} do
    user = insert(:user)
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, ~p"/chat")

    payload = %{
      "permission" => "granted",
      "subscribed" => true,
      "subscription" => String.trim(@subscription_json)
    }

    render_hook(view, "push:status", payload)
    render_hook(view, "push:status", payload)
    render_hook(view, "push:status", payload)

    rows = Repo.all(from(dt in DeviceToken, where: dt.user_id == ^user.id))
    assert length(rows) == 1
  end

  test "push:status with subscribed=false leaves the database alone", %{conn: conn} do
    user = insert(:user)
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, ~p"/chat")

    render_hook(view, "push:status", %{
      "permission" => "default",
      "subscribed" => false,
      "subscription" => nil
    })

    assert Repo.all(from(dt in DeviceToken, where: dt.user_id == ^user.id)) == []
  end

  test "push:status without subscription field is backward-compatible", %{conn: conn} do
    user = insert(:user)
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, ~p"/chat")

    # Older client builds may push only permission + subscribed
    render_hook(view, "push:status", %{
      "permission" => "granted",
      "subscribed" => true
    })

    assert Repo.all(from(dt in DeviceToken, where: dt.user_id == ^user.id)) == []
  end
end
