defmodule SlackexWeb.API.DeviceTokenJSON do
  @moduledoc """
  Serializes DeviceToken structs to JSON-safe maps.
  """

  alias Slackex.Notifications.DeviceToken

  def data(%{device_token: device_token}), do: %{device_token: serialize(device_token)}

  defp serialize(%DeviceToken{id: id, token: token, platform: platform, device_name: device_name}) do
    %{
      id: id,
      token: token,
      platform: platform,
      device_name: device_name
    }
  end
end
