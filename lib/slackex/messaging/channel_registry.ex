defmodule Slackex.Messaging.ChannelRegistry do
  @moduledoc """
  Distributed process registry for channel and DM servers using Horde.Registry.

  Wraps `Horde.Registry` with `members: :auto` so all nodes in the cluster
  automatically share the registry. Provides helpers for building `{:via, ...}`
  tuples used when starting and looking up `ChannelServer` processes.
  """

  def child_spec(_opts) do
    Horde.Registry.child_spec(
      name: __MODULE__,
      keys: :unique,
      members: :auto
    )
  end

  def start_link(opts \\ []) do
    Horde.Registry.start_link(
      Keyword.merge([name: __MODULE__, keys: :unique, members: :auto], opts)
    )
  end

  @doc "Looks up a registered channel or DM server. Returns `[{pid, value}]` or `[]`."
  def lookup({:channel, id}), do: Horde.Registry.lookup(__MODULE__, {:channel, id})
  def lookup({:dm, id}), do: Horde.Registry.lookup(__MODULE__, {:dm, id})

  @doc "Returns a `{:via, Horde.Registry, ...}` tuple for a channel server."
  def via(channel_id), do: {:via, Horde.Registry, {__MODULE__, {:channel, channel_id}}}

  @doc "Returns a `{:via, Horde.Registry, ...}` tuple for a DM server."
  def via_dm(dm_id), do: {:via, Horde.Registry, {__MODULE__, {:dm, dm_id}}}

  @doc "Returns the total number of registered processes."
  def count, do: Horde.Registry.count(__MODULE__)
end
