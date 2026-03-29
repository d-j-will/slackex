defmodule Slackex.Integrations.McpTokensTest do
  use Slackex.DataCase, async: true

  alias Slackex.Integrations.McpTokens

  describe "create_mcp_token/1" do
    test "creates token with bot user atomically" do
      assert {:ok, %{mcp_token: token, raw_token: raw, bot_user: bot}} =
               McpTokens.create_mcp_token(%{name: "Claude Code"})

      assert token.name == "Claude Code"
      assert token.is_active == true
      assert token.bot_user_id == bot.id
      assert is_binary(raw)
      assert String.starts_with?(raw, "mcp_")
      assert token.token_hash == McpTokens.hash_token(raw)

      # Bot user created with is_bot flag
      assert bot.is_bot == true
      assert bot.username == "mcp-claude-code"
      assert bot.display_name == "Claude Code"
    end

    test "returns raw token that differs from stored hash" do
      {:ok, %{mcp_token: token, raw_token: raw}} =
        McpTokens.create_mcp_token(%{name: "Test Agent"})

      assert raw != token.token_hash
      assert McpTokens.hash_token(raw) == token.token_hash
    end
  end

  describe "get_by_token_hash/1" do
    test "finds active token with preloaded bot_user" do
      {:ok, %{mcp_token: token}} =
        McpTokens.create_mcp_token(%{name: "Lookup Test"})

      found = McpTokens.get_by_token_hash(token.token_hash)
      assert found.id == token.id
      assert found.bot_user.is_bot == true
    end

    test "returns nil for inactive token" do
      {:ok, %{mcp_token: token}} =
        McpTokens.create_mcp_token(%{name: "Inactive"})

      McpTokens.revoke_mcp_token(token)
      assert nil == McpTokens.get_by_token_hash(token.token_hash)
    end

    test "returns nil for unknown hash" do
      assert nil == McpTokens.get_by_token_hash("nonexistent")
    end
  end

  describe "revoke_mcp_token/1" do
    test "sets is_active to false" do
      {:ok, %{mcp_token: token}} =
        McpTokens.create_mcp_token(%{name: "Revoke Test"})

      assert {:ok, revoked} = McpTokens.revoke_mcp_token(token)
      assert revoked.is_active == false
    end
  end

  describe "touch_last_used/1" do
    test "updates last_used_at timestamp when nil" do
      {:ok, %{mcp_token: token}} =
        McpTokens.create_mcp_token(%{name: "Touch Test"})

      assert token.last_used_at == nil
      assert {:ok, touched} = McpTokens.touch_last_used(token)
      assert touched.last_used_at != nil
    end

    test "skips update when last_used_at is recent (within 5 minutes)" do
      {:ok, %{mcp_token: token}} =
        McpTokens.create_mcp_token(%{name: "Debounce Test"})

      recent = DateTime.utc_now() |> DateTime.add(-60, :second)
      {:ok, token} = token |> Ecto.Changeset.change(last_used_at: recent) |> Slackex.Repo.update()

      assert :debounced = McpTokens.touch_last_used(token)
    end

    test "updates when last_used_at is older than 5 minutes" do
      {:ok, %{mcp_token: token}} =
        McpTokens.create_mcp_token(%{name: "Stale Test"})

      stale = DateTime.utc_now() |> DateTime.add(-400, :second)
      {:ok, token} = token |> Ecto.Changeset.change(last_used_at: stale) |> Slackex.Repo.update()

      assert {:ok, updated} = McpTokens.touch_last_used(token)
      assert DateTime.diff(updated.last_used_at, stale) > 300
    end
  end
end
