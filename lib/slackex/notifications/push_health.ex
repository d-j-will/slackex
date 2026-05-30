defmodule Slackex.Notifications.PushHealth do
  @moduledoc """
  Derives the push-notification deliverability badge shown in the UI.

  Extracted from `SlackexWeb.ChatLive.Index` so the derivation is unit-testable
  without a LiveView socket. The web layer adapts socket assigns into the three
  plain inputs and assigns the result.
  """

  alias Slackex.Notifications.DeviceTokens

  @typedoc """
  Push deliverability state:

    * `:browser_blocked` — the browser denied notification permission
    * `:ok`              — subscribed *and* a delivery token exists
    * `:not_set_up`      — anything else
  """
  @type t :: :ok | :browser_blocked | :not_set_up

  @doc """
  Derives push health from the browser `permission` string, the client's
  `subscribed?` flag, and whether a `DeviceToken` row exists for the user.

  A denied permission takes precedence over everything else.
  """
  def derive("denied", _subscribed?, _user_id), do: :browser_blocked

  def derive(_permission, true, user_id) do
    if DeviceTokens.exists?(user_id), do: :ok, else: :not_set_up
  end

  def derive(_permission, _subscribed?, _user_id), do: :not_set_up
end
