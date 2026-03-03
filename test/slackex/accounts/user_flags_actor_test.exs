defmodule Slackex.Accounts.UserFlagsActorTest do
  use Slackex.DataCase, async: true

  describe "FunWithFlags.Actor protocol" do
    test "returns user:<id> as the actor id" do
      user = insert(:user)
      assert FunWithFlags.Actor.id(user) == "user:#{user.id}"
    end

    test "works with the FunWithFlags.enabled?/2 actor check" do
      user = insert(:user)

      # Ensure the flag is off by default
      FunWithFlags.disable(:test_actor_flag)
      refute FunWithFlags.enabled?(:test_actor_flag, for: user)

      # Enable for this specific user
      FunWithFlags.enable(:test_actor_flag, for_actor: user)
      assert FunWithFlags.enabled?(:test_actor_flag, for: user)

      # Clean up
      FunWithFlags.disable(:test_actor_flag)
    end
  end
end
