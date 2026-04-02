defmodule Slackex.Notifications.MentionTest do
  use ExUnit.Case, async: true

  alias Slackex.Notifications.Mention

  describe "mentioned?/2" do
    test "detects @username mention" do
      assert Mention.mentioned?("hey @alice check this", "alice")
    end

    test "is case-insensitive" do
      assert Mention.mentioned?("hey @Alice check this", "alice")
    end

    test "does not match partial words" do
      refute Mention.mentioned?("paying with cash", "ash")
      refute Mention.mentioned?("the dashboard is broken", "ash")
    end

    test "matches at start of string" do
      assert Mention.mentioned?("@bob hello", "bob")
    end

    test "matches at end of string" do
      assert Mention.mentioned?("hello @bob", "bob")
    end

    test "does not match without @ prefix" do
      refute Mention.mentioned?("hey bob check this", "bob")
    end

    test "handles special regex characters in username" do
      assert Mention.mentioned?("hey @user.name check", "user.name")
    end

    test "does not match email-like patterns" do
      refute Mention.mentioned?("email me at bob@example.com", "bob")
    end
  end
end
