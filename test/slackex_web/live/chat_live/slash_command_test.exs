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
  end
end
