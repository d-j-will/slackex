defmodule Slackex.NodeListener do
  @moduledoc """
  Monitors node join/leave events in a distributed cluster.

  Subscribes to `:net_kernel` node monitoring and logs when nodes
  join or leave the cluster. Intended to be started in the supervision
  tree alongside libcluster.
  """

  # Cluster bootstrap (nodeup/nodedown): intentionally outside context
  # boundaries, checks off (boundary has no ignore option; unchecked = ignored).
  use Boundary, check: [in: false, out: false]

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @cluster_check_delay_ms 30_000

  @impl true
  def init(_opts) do
    _ = :net_kernel.monitor_nodes(true, node_type: :visible)
    Process.send_after(self(), :log_cluster_status, @cluster_check_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:log_cluster_status, state) do
    peers = Node.list()
    cluster_size = length(peers) + 1

    if peers == [] do
      Logger.warning("Cluster status: running as single node (no peers discovered after 30s)")
    else
      Logger.info(
        "Cluster status: #{cluster_size} nodes — #{Enum.map_join(peers, ", ", &Atom.to_string/1)}"
      )
    end

    {:noreply, state}
  end

  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node joined cluster: #{node}")
    {:noreply, state}
  end

  def handle_info({:nodedown, node, _info}, state) do
    Logger.info("Node left cluster: #{node}")
    {:noreply, state}
  end
end
