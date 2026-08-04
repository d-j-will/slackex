defmodule Slackex.NodeListenerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Slackex.NodeListener

  # A "starts and registers under its module name" test lived here. It called
  # GenServer.start_link/2 and asserted the returned pid was alive -- which is
  # what start_link/2 returning {:ok, pid} already means, so it asserted OTP.
  # The name was also a promise the body never kept: it started the process
  # unnamed and never checked any registration. The handle_info tests below do
  # exercise our clauses, and a missing one would crash the process, so the
  # liveness assertions there are load-bearing in a way this one was not.

  describe "handle_info/2" do
    setup do
      {:ok, pid} = GenServer.start_link(NodeListener, [])

      on_exit(fn ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

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

    test "logs cluster status as single node when no peers discovered", %{pid: pid} do
      log =
        capture_log(fn ->
          send(pid, :log_cluster_status)
          # :sys.get_state is synchronous — ensures the message has been processed
          :sys.get_state(pid)
        end)

      assert log =~ "running as single node"
    end
  end
end
