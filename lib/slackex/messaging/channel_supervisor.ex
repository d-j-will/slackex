defmodule Slackex.Messaging.ChannelSupervisor do
  @moduledoc """
  Horde.DynamicSupervisor for `ChannelServer` processes.

  One supervisor manages all active channel and DM servers. Use
  `ensure_started/2` to start (or locate) a server for a given channel or DM.
  """

  alias Slackex.Messaging.ChannelServer

  def child_spec(opts) do
    Horde.DynamicSupervisor.child_spec(
      Keyword.merge(
        [
          name: __MODULE__,
          strategy: :one_for_one,
          members: :auto,
          process_redistribution: :active
        ],
        opts
      )
    )
  end

  @doc "Starts the supervisor under the application supervision tree."
  def start_link(opts) do
    Horde.DynamicSupervisor.start_link(
      [name: __MODULE__, strategy: :one_for_one, members: :auto, process_redistribution: :active] ++
        opts
    )
  end

  def init(_opts) do
    Horde.DynamicSupervisor.init(
      strategy: :one_for_one,
      members: :auto,
      process_redistribution: :active
    )
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

    case Horde.Registry.lookup(Slackex.Messaging.ChannelRegistry, {type, id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child_spec = {ChannelServer, {id, channel_opts}}

        case Horde.DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end
end
