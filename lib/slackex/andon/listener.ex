defmodule Slackex.Andon.Listener do
  @moduledoc """
  Subscribes to relay-enabled channels' PubSub topics and turns each
  `message.new` into a domain event via `Slackex.Andon.process_message/2`.

  Modelled on `Slackex.Factory.ChannelNotifier`: supervised `restart:
  :temporary` (relay failures must never take down chat) and gated behind
  `FunWithFlags.enabled?(:andon_relay)` — with the flag off the process runs
  but does nothing, so the feature is dark-shipped and inert.

  Channel enablement is dynamic: the listener also subscribes to the control
  topic, and `Slackex.Andon.enable_channel/1` announces new channels there so
  every node's listener picks them up without a restart. On boot it re-loads
  the already-enabled channels from the DB (disabled in test, where each test
  starts its own listener with explicit `:channels`).
  """
  use GenServer

  require Logger

  alias Slackex.Andon

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    _ = Phoenix.PubSub.subscribe(Slackex.PubSub, Andon.control_topic())

    channels =
      opts
      |> Keyword.get(:channels, [])
      |> subscribe_all()

    state = %{channels: channels, bot_id: Keyword.get(opts, :bot_id)}

    if subscribe_on_boot?(opts) do
      {:ok, state, {:continue, :load_channels}}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:load_channels, state) do
    channels =
      Andon.enabled_channel_ids()
      |> subscribe_all(state.channels)

    {:noreply, %{state | channels: channels}}
  rescue
    # At boot the sandbox/DB may not be ready (e.g. test env); the control
    # topic still delivers future enablements, so this is a warning, not fatal.
    error ->
      Logger.warning("andon relay: could not load enabled channels on boot: #{inspect(error)}")
      {:noreply, state}
  end

  @impl GenServer
  def handle_info({:andon_channel_enabled, channel_id}, state) do
    channels = subscribe_all([channel_id], state.channels)
    {:noreply, %{state | channels: channels}}
  end

  def handle_info(
        {:envelope, %{event: "message.new", target: %{id: channel_id}, payload: payload}},
        state
      ) do
    state =
      if FunWithFlags.enabled?(:andon_relay) and MapSet.member?(state.channels, channel_id) do
        process(payload, channel_id, state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- internals --------------------------------------------------------------

  defp process(payload, channel_id, state) do
    state = ensure_bot(state)
    Andon.process_message(payload, %{channel_id: channel_id, bot_id: state.bot_id})
    state
  end

  defp ensure_bot(%{bot_id: nil} = state), do: %{state | bot_id: Andon.bot_user().id}
  defp ensure_bot(state), do: state

  defp subscribe_all(channel_ids, acc \\ MapSet.new()) do
    Enum.reduce(channel_ids, acc, fn channel_id, set ->
      if MapSet.member?(set, channel_id) do
        set
      else
        _ = Slackex.Messaging.subscribe_channel(channel_id)
        MapSet.put(set, channel_id)
      end
    end)
  end

  defp subscribe_on_boot?(opts) do
    Keyword.get(
      opts,
      :subscribe_on_boot,
      Application.get_env(:slackex, :andon_subscribe_on_boot, true)
    )
  end
end
