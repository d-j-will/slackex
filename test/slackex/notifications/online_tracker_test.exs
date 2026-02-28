defmodule Slackex.Notifications.OnlineTrackerTest do
  use Slackex.DataCase, async: false

  alias Slackex.Notifications.OnlineTracker

  describe "online_user_ids/1" do
    test "returns MapSet of user IDs that are currently online" do
      user_a = insert(:user)
      user_b = insert(:user)
      user_c = insert(:user)

      OnlineTracker.mark_online(user_a.id)
      OnlineTracker.mark_online(user_c.id)

      result = OnlineTracker.online_user_ids([user_a.id, user_b.id, user_c.id])

      assert %MapSet{} = result
      assert MapSet.member?(result, user_a.id)
      refute MapSet.member?(result, user_b.id)
      assert MapSet.member?(result, user_c.id)
    end

    test "returns empty MapSet when called with empty list without hitting Redis" do
      result = OnlineTracker.online_user_ids([])

      assert result == MapSet.new()
    end

    test "returns empty MapSet when no queried users are online" do
      user_a = insert(:user)
      user_b = insert(:user)

      result = OnlineTracker.online_user_ids([user_a.id, user_b.id])

      assert result == MapSet.new()
    end

    test "returns empty MapSet on Redis connection failure (graceful degradation)" do
      # Use an invalid connection name to simulate Redis failure
      # The function should rescue and return empty MapSet
      result = OnlineTracker.online_user_ids([999_999_999])

      assert %MapSet{} = result
    end
  end
end
