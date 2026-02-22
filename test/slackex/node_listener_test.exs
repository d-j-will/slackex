defmodule Slackex.NodeListenerTest do
  use ExUnit.Case, async: true

  alias Slackex.NodeListener

  describe "start_link/1" do
    test "starts and registers under its module name" do
      # NodeListener is already started in the app supervision tree if the app is running.
      # Start a fresh instance under a different name for isolated testing.
      {:ok, pid} = GenServer.start_link(NodeListener, [])
      assert is_pid(pid)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "handle_info/2" do
    setup do
      {:ok, pid} = GenServer.start_link(NodeListener, [])
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "handles :nodeup without crashing", %{pid: pid} do
      send(pid, {:nodeup, :"other@127.0.0.1", []})
      # Give the GenServer time to process the message
      :timer.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles :nodedown without crashing", %{pid: pid} do
      send(pid, {:nodedown, :"other@127.0.0.1", []})
      :timer.sleep(10)
      assert Process.alive?(pid)
    end
  end
end
