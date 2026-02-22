defmodule Slackex.Messaging.ChannelRegistryTest do
  use ExUnit.Case, async: false

  alias Slackex.Messaging.ChannelRegistry

  # Start an isolated Horde.Registry for each test to avoid interference
  # with the application-level ChannelRegistry.
  setup do
    registry_name = :"test_channel_registry_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Horde.Registry.start_link(name: registry_name, keys: :unique, members: :auto)

    %{registry: registry_name}
  end

  describe "via/1" do
    test "returns correct via tuple for channel" do
      assert ChannelRegistry.via(42) ==
               {:via, Horde.Registry, {ChannelRegistry, {:channel, 42}}}
    end

    test "returns correct via tuple for string channel id" do
      assert ChannelRegistry.via("general") ==
               {:via, Horde.Registry, {ChannelRegistry, {:channel, "general"}}}
    end
  end

  describe "via_dm/1" do
    test "returns correct via tuple for DM" do
      assert ChannelRegistry.via_dm(99) ==
               {:via, Horde.Registry, {ChannelRegistry, {:dm, 99}}}
    end
  end

  describe "lookup/1" do
    test "returns empty list for unregistered channel key" do
      # Use the app-level registry; no channel server registered for this id
      result = ChannelRegistry.lookup({:channel, 999_999_999})
      assert result == []
    end

    test "returns empty list for unregistered DM key" do
      result = ChannelRegistry.lookup({:dm, 999_999_999})
      assert result == []
    end
  end
end
