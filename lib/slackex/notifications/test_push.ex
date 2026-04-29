defmodule Slackex.Notifications.TestPush do
  @moduledoc """
  Fires a synthetic push to every device token registered for a user.
  Used by the in-app "Send test notification" button so users can verify
  their full push path end-to-end without waiting for a real message.
  """

  import Ecto.Query

  alias Slackex.Notifications.DeviceToken
  alias Slackex.Repo

  @spec send(integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def send(user_id) do
    tokens =
      Repo.all(
        from dt in DeviceToken,
          where: dt.user_id == ^user_id,
          select: %{token: dt.token, platform: dt.platform}
      )

    adapter = Application.get_env(:slackex, :push_adapter, Slackex.Notifications.PushAdapter.Stub)
    payload = build_payload()

    results = Enum.map(tokens, &adapter.send_push(&1.token, &1.platform, payload))

    cond do
      results == [] -> {:ok, 0}
      Enum.all?(results, &(&1 == :ok)) -> {:ok, length(results)}
      true -> {:error, Enum.find(results, fn r -> match?({:error, _}, r) end)}
    end
  end

  defp build_payload do
    %{
      "title" => "Tenun test notification",
      "body" => "If you see this, push notifications are working.",
      "tag" => "tenun-test",
      "url" => "/chat",
      "type" => "test"
    }
  end
end
