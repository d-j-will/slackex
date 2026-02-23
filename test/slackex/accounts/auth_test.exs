defmodule Slackex.Accounts.AuthTest do
  use Slackex.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Slackex.Accounts.Auth
  alias Slackex.Repo

  setup do
    user = insert(:user)
    %{user: user}
  end

  describe "refresh_api_token/1" do
    test "valid refresh token returns new access and refresh tokens", %{user: user} do
      refresh_token = Auth.generate_refresh_token(user)

      assert {:ok, %{access_token: access, refresh_token: new_refresh}} =
               Auth.refresh_api_token(refresh_token)

      assert is_binary(access)
      assert is_binary(new_refresh)
      assert new_refresh != refresh_token
    end

    test "invalid token returns error", _context do
      assert {:error, _} = Auth.refresh_api_token("garbage.invalid.token")
    end

    test "already-revoked token within grace window returns :token_recently_rotated", %{
      user: user
    } do
      refresh_token = Auth.generate_refresh_token(user)

      # First rotation succeeds
      assert {:ok, _} = Auth.refresh_api_token(refresh_token)

      # Immediate retry hits grace window
      assert {:error, :token_recently_rotated} = Auth.refresh_api_token(refresh_token)
    end

    test "concurrent refresh attempts allow only one to succeed", %{user: user} do
      refresh_token = Auth.generate_refresh_token(user)
      parent = self()

      tasks =
        Enum.map(1..2, fn _ ->
          Task.async(fn ->
            SQL.Sandbox.allow(Repo, parent, self())
            Auth.refresh_api_token(refresh_token)
          end)
        end)

      results = Task.await_many(tasks)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      assert successes == 1

      assert Enum.all?(results, fn
               {:ok, %{access_token: _, refresh_token: _}} -> true
               {:error, :token_recently_rotated} -> true
               _ -> false
             end)
    end
  end
end
