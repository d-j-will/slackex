defmodule Slackex.Messaging.ChannelSupervisor do
  @moduledoc """
  DynamicSupervisor for `ChannelServer` processes.

  One supervisor manages all active channel and DM servers. Use
  `ensure_started/2` to start (or locate) a server for a given channel or DM.
  """

  use DynamicSupervisor

  alias Slackex.Messaging.ChannelServer

  @doc "Starts the supervisor under the application supervision tree."
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Ensures a `ChannelServer` is running for `target`.

  `target` is `{:channel, channel_id}` or `{:dm, dm_id}`.
  Returns `{:ok, pid}` whether the server was just started or already running.
  """
  @spec ensure_started({:channel | :dm, integer()}, keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(target, opts \\ []) do
    {type, id} = target
    channel_opts = Keyword.put_new(opts, :channel_type, type)

    case Registry.lookup(Slackex.Messaging.ChannelRegistry, {type, id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child_spec = {ChannelServer, {id, channel_opts}}

        case DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end
end
