defmodule Slackex.Links.SafetyCheckerTest do
  use ExUnit.Case, async: true

  alias Slackex.Links.SafetyChecker

  describe "check_domain/1" do
    test "blocks known blocked domains" do
      assert {:blocked, "blocklist"} = SafetyChecker.check_domain("https://pornhub.com/video")
    end

    test "blocks subdomains of blocked domains" do
      assert {:blocked, "blocklist"} = SafetyChecker.check_domain("https://www.pornhub.com")
      assert {:blocked, "blocklist"} = SafetyChecker.check_domain("https://m.xvideos.com")
    end

    test "allows safe domains" do
      assert :ok = SafetyChecker.check_domain("https://elixir-lang.org")
      assert :ok = SafetyChecker.check_domain("https://github.com")
    end

    test "handles invalid URLs gracefully" do
      assert {:blocked, "invalid_url"} = SafetyChecker.check_domain("not-a-url")
    end
  end

  describe "check_safe_browsing/1" do
    test "returns :ok when safe browsing is not configured" do
      # GOOGLE_SAFE_BROWSING_KEY is not set in test env
      assert :ok = SafetyChecker.check_safe_browsing("https://example.com")
    end
  end

  describe "check/1" do
    test "short-circuits on blocklist match" do
      assert {:blocked, "blocklist"} = SafetyChecker.check("https://pornhub.com")
    end

    test "passes safe URLs through all checks" do
      assert :ok = SafetyChecker.check("https://elixir-lang.org")
    end
  end
end
