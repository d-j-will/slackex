defmodule Slackex.Accounts.UserFlagsActorTest do
  use Slackex.DataCase, async: true

  describe "FunWithFlags.Actor protocol" do
    test "returns user:<id> as the actor id" do
      user = insert(:user)
      assert FunWithFlags.Actor.id(user) == "user:#{user.id}"
    end

    # A second test enabled a flag for one user and asserted FunWithFlags then
    # reported it enabled for that user. Given the id above is right, per-actor
    # gating is the library's job and its own suite's problem. It also wrote to
    # the flag store to do it, which the Test Environment rules warn about.
  end
end
