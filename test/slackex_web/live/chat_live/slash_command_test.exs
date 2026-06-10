defmodule SlackexWeb.ChatLive.SlashCommandTest do
  use ExUnit.Case, async: true

  alias SlackexWeb.ChatLive.SlashCommand

  describe "parse/1" do
    test "parses /summarize with no args as 24h" do
      assert {:summarize, "24h"} = SlashCommand.parse("/summarize")
    end

    test "parses /summarize 7d" do
      assert {:summarize, "7d"} = SlashCommand.parse("/summarize 7d")
    end

    test "parses /summarize 30d" do
      assert {:summarize, "30d"} = SlashCommand.parse("/summarize 30d")
    end

    test "returns :not_command for regular messages" do
      assert :not_command = SlashCommand.parse("hello world")
    end

    test "returns :not_command for empty string" do
      assert :not_command = SlashCommand.parse("")
    end

    test "returns :unknown_command for unrecognized slash commands" do
      assert {:unknown_command, "foo"} = SlashCommand.parse("/foo")
    end

    test "handles whitespace" do
      assert {:summarize, "7d"} = SlashCommand.parse("  /summarize  7d  ")
    end

    test "/decide parses to {:decide}" do
      assert SlashCommand.parse("/decide") == {:decide}
      assert SlashCommand.parse("  /decide  ") == {:decide}
    end

    test "non-decide input is unaffected" do
      assert SlashCommand.parse("/summarize") == {:summarize, "24h"}
      assert SlashCommand.parse("hello") == :not_command
    end
  end

  describe "subscribe-bot / unsubscribe-bot" do
    test "/subscribe-bot with a name parses to a subscribe action" do
      assert {:bot_subscription, {:subscribe, "claude-code-max"}} =
               SlashCommand.parse("/subscribe-bot claude-code-max")
    end

    test "/subscribe-bot trims surrounding whitespace from the name" do
      assert {:bot_subscription, {:subscribe, "claude-code-max"}} =
               SlashCommand.parse("  /subscribe-bot   claude-code-max  ")
    end

    test "/subscribe-bot with no name parses to help" do
      assert {:bot_subscription, :subscribe_help} = SlashCommand.parse("/subscribe-bot")
    end

    test "/unsubscribe-bot with a name parses to an unsubscribe action" do
      assert {:bot_subscription, {:unsubscribe, "claude-code-max"}} =
               SlashCommand.parse("/unsubscribe-bot claude-code-max")
    end

    test "/unsubscribe-bot with no name parses to help" do
      assert {:bot_subscription, :unsubscribe_help} = SlashCommand.parse("/unsubscribe-bot")
    end

    test "near-miss commands stay unknown" do
      assert {:unknown_command, "subscribe-bots"} = SlashCommand.parse("/subscribe-bots x")
    end
  end
end
