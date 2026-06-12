defmodule SlackexWeb.ChatLive.BotSubscription do
  @moduledoc """
  Handles the `/subscribe-bot` and `/unsubscribe-bot` slash commands.

  Resolves the bare bot name the owner typed (`claude-code-max`) to the bot
  user minted at MCP-token time (`mcp-claude-code-max`, `is_bot: true`) and
  adds/removes its `subscriptions` row in the active channel via
  `Chat.Members`. Feedback is a private flash to the owner — never a posted
  message (a posted message would be persisted, broadcast, and indexed).

  Gated behind `:bot_subscription`. Flag off, both commands answer
  `"Unknown command"` so the feature's existence is not leaked (the `/decide`
  discipline). Full design: docs/superpowers/specs/2026-06-06-bot-channel-subscription-design.md
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Slackex.Accounts
  alias Slackex.Chat.Members

  @type action ::
          {:subscribe, String.t()}
          | :subscribe_help
          | {:unsubscribe, String.t()}
          | :unsubscribe_help

  @spec handle(Phoenix.LiveView.Socket.t(), Slackex.Accounts.User.t(), action()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle(socket, user, action) do
    socket =
      if FunWithFlags.enabled?(:bot_subscription, for: user) do
        run(socket, user, action)
      else
        put_flash(socket, :error, "Unknown command: /#{command_name(action)}")
      end

    {:noreply, socket}
  end

  defp run(socket, _user, :subscribe_help),
    do: put_flash(socket, :info, "Usage: /subscribe-bot <name> — <name> is the label chosen at MCP token creation (bot username becomes mcp-<name>)")

  defp run(socket, _user, :unsubscribe_help),
    do: put_flash(socket, :info, "Usage: /unsubscribe-bot <name> — <name> is the label chosen at MCP token creation (bot username becomes mcp-<name>)")

  defp run(socket, user, {op, name}) do
    case {socket.assigns.active_channel, Accounts.get_bot_by_username("mcp-" <> name)} do
      {nil, _} ->
        put_flash(socket, :error, "Run /#{command_name(op)} inside a channel")

      {_channel, nil} ->
        put_flash(socket, :error, "No bot named '#{name}' found")

      {channel, bot} ->
        execute(socket, op, channel, user, bot, name)
    end
  end

  defp execute(socket, :subscribe, channel, user, bot, name) do
    case Members.add_bot_member(channel.id, user.id, bot.id) do
      {:ok, :already_subscribed} ->
        put_flash(socket, :info, "#{name} is already subscribed to ##{channel.name}")

      {:ok, _subscription} ->
        socket
        |> clear_input()
        |> put_flash(
          :info,
          "✓ #{name} subscribed to ##{channel.name} — channel_id: #{channel.id} " <>
            "(use as the target for send_message / reply_to_thread)"
        )

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason, name))
    end
  end

  defp execute(socket, :unsubscribe, channel, user, bot, name) do
    case Members.remove_bot_member(channel.id, user.id, bot.id) do
      :ok ->
        socket
        |> clear_input()
        |> put_flash(:info, "✓ #{name} unsubscribed from ##{channel.name}")

      {:error, :not_a_member} ->
        put_flash(socket, :error, "#{name} is not subscribed to this channel")

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason, name))
    end
  end

  defp error_message(:unauthorized, _name),
    do: "You need the manage-members permission to manage bots in this channel"

  defp error_message(:private_channel_not_supported, _name),
    do: "Bots can only be subscribed to public channels"

  defp error_message(_other, name),
    do: "Could not update the subscription for #{name}"

  defp clear_input(socket),
    do: assign(socket, :message_form, to_form(%{"content" => ""}, as: :message))

  defp command_name({:subscribe, _name}), do: "subscribe-bot"
  defp command_name(:subscribe), do: "subscribe-bot"
  defp command_name(:subscribe_help), do: "subscribe-bot"
  defp command_name({:unsubscribe, _name}), do: "unsubscribe-bot"
  defp command_name(:unsubscribe), do: "unsubscribe-bot"
  defp command_name(:unsubscribe_help), do: "unsubscribe-bot"
end
