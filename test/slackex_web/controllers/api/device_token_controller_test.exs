defmodule SlackexWeb.API.DeviceTokenControllerTest do
  use SlackexWeb.ConnCase, async: true

  import Ecto.Query
  import Slackex.TestFactory

  alias Slackex.Accounts.Auth
  alias Slackex.Notifications.DeviceToken
  alias Slackex.Repo

  setup %{conn: conn} do
    user = insert(:user)
    token = Auth.generate_api_token(user)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    %{conn: conn, user: user}
  end

  describe "POST /api/device-tokens" do
    test "creates device token with valid params and returns 201", %{conn: conn, user: user} do
      conn = post(conn, ~p"/api/device-tokens", %{token: "fcm-tok-1", platform: "fcm"})

      assert %{"device_token" => dt} = json_response(conn, 201)
      assert dt["token"] == "fcm-tok-1"
      assert dt["platform"] == "fcm"

      assert Repo.get_by(DeviceToken, token: "fcm-tok-1", user_id: user.id)
    end

    test "creates device token with apns platform", %{conn: conn} do
      conn = post(conn, ~p"/api/device-tokens", %{token: "apns-tok-1", platform: "apns"})

      assert %{"device_token" => dt} = json_response(conn, 201)
      assert dt["platform"] == "apns"
    end

    test "creates device token with optional device_name", %{conn: conn} do
      conn =
        post(conn, ~p"/api/device-tokens", %{
          token: "tok-named",
          platform: "fcm",
          device_name: "iPhone 15"
        })

      assert %{"device_token" => dt} = json_response(conn, 201)
      assert dt["device_name"] == "iPhone 15"
    end

    test "returns 422 with invalid platform", %{conn: conn} do
      conn = post(conn, ~p"/api/device-tokens", %{token: "bad-platform-tok", platform: "safari"})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["platform"] != nil
    end

    test "returns 400 when token param is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/device-tokens", %{platform: "fcm"})

      assert %{"error" => "missing_params"} = json_response(conn, 400)
    end

    test "returns 400 when platform param is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/device-tokens", %{token: "some-tok"})

      assert %{"error" => "missing_params"} = json_response(conn, 400)
    end

    test "upserts existing token for same user (updates device_name)", %{conn: conn, user: user} do
      insert(:device_token, user: user, token: "upsert-tok", platform: "fcm")

      conn =
        post(conn, ~p"/api/device-tokens", %{
          token: "upsert-tok",
          platform: "apns",
          device_name: "iPad"
        })

      assert %{"device_token" => dt} = json_response(conn, 201)
      assert dt["platform"] == "apns"
      assert dt["device_name"] == "iPad"

      # Only one record with this token for this user
      assert Repo.aggregate(
               from(d in DeviceToken, where: d.token == "upsert-tok" and d.user_id == ^user.id),
               :count
             ) == 1
    end

    test "returns 401 when unauthenticated" do
      conn = build_conn()
      conn = post(conn, ~p"/api/device-tokens", %{token: "t", platform: "fcm"})
      assert %{"error" => _} = json_response(conn, 401)
    end
  end

  describe "DELETE /api/device-tokens" do
    test "deletes existing token for current user and returns 204", %{conn: conn, user: user} do
      insert(:device_token, user: user, token: "del-tok", platform: "fcm")

      conn = delete(conn, ~p"/api/device-tokens", %{token: "del-tok"})

      assert response(conn, 204) == ""
      refute Repo.get_by(DeviceToken, token: "del-tok")
    end

    test "returns 404 when token does not exist", %{conn: conn} do
      conn = delete(conn, ~p"/api/device-tokens", %{token: "nonexistent-tok"})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 404 when token belongs to different user", %{conn: conn} do
      other_user = insert(:user)
      insert(:device_token, user: other_user, token: "other-user-tok", platform: "fcm")

      conn = delete(conn, ~p"/api/device-tokens", %{token: "other-user-tok"})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 400 when token param is missing", %{conn: conn} do
      conn = delete(conn, ~p"/api/device-tokens", %{})

      assert %{"error" => "missing_params"} = json_response(conn, 400)
    end

    test "returns 401 when unauthenticated" do
      conn = build_conn()
      conn = delete(conn, ~p"/api/device-tokens", %{token: "t"})
      assert %{"error" => _} = json_response(conn, 401)
    end
  end
end
