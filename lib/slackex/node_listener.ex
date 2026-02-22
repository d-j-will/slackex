defmodule Slackex.NodeListener do
  @moduledoc """
  Monitors node join/leave events in a distributed cluster.

  Subscribes to `:net_kernel` node monitoring and logs when nodes
  join or leave the cluster. Intended to be started in the supervision
  tree alongside libcluster.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node joined cluster: #{node}")
    {:noreply, state}
  end

  def handle_info({:nodedown, node, _info}, state) do
    Logger.info("Node left cluster: #{node}")
    {:noreply, state}
  end
end
