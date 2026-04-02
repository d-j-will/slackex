defmodule Slackex.Notifications.PreferenceTest do
  use Slackex.DataCase, async: true

  alias Slackex.Notifications.Preference

  describe "resolve_level/2" do
    test "returns per-channel level when set" do
      user = insert(:user)
      channel = insert(:channel)
      Preference.set_preference(user.id, channel.id, "nothing")
      assert Preference.resolve_level(user.id, channel.id) == "nothing"
    end

    test "falls back to global default when no per-channel preference" do
      user = insert(:user)
      channel = insert(:channel)
      Preference.set_global_default(user.id, "mentions")
      assert Preference.resolve_level(user.id, channel.id) == "mentions"
    end

    test "returns 'all' when no preferences exist" do
      user = insert(:user)
      channel = insert(:channel)
      assert Preference.resolve_level(user.id, channel.id) == "all"
    end
  end

  describe "set_preference/3" do
    test "creates a per-channel preference" do
      user = insert(:user)
      channel = insert(:channel)
      assert {:ok, pref} = Preference.set_preference(user.id, channel.id, "mentions")
      assert pref.level == "mentions"
      assert pref.channel_id == channel.id
    end

    test "updates existing preference" do
      user = insert(:user)
      channel = insert(:channel)
      {:ok, _} = Preference.set_preference(user.id, channel.id, "mentions")
      {:ok, pref} = Preference.set_preference(user.id, channel.id, "nothing")
      assert pref.level == "nothing"
    end
  end

  describe "set_global_default/2" do
    test "creates and updates the global default level" do
      user = insert(:user)
      {:ok, pref} = Preference.set_global_default(user.id, "mentions")
      assert pref.level == "mentions"
      assert is_nil(pref.channel_id)

      {:ok, updated} = Preference.set_global_default(user.id, "nothing")
      assert updated.level == "nothing"
    end
  end

  describe "create_default_for_user/1" do
    test "creates global default with level 'all'" do
      user = insert(:user)
      assert {:ok, pref} = Preference.create_default_for_user(user.id)
      assert pref.level == "all"
      assert is_nil(pref.channel_id)
    end

    test "is idempotent" do
      user = insert(:user)
      {:ok, _} = Preference.create_default_for_user(user.id)
      # Should not raise on second call
      assert {:ok, _} = Preference.create_default_for_user(user.id)
    end
  end
end
