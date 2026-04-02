defmodule Slackex.Notifications.DeviceToken do
  @moduledoc "Stores FCM/APNs push notification tokens per user device."

  use Ecto.Schema

  import Ecto.Changeset

  schema "device_tokens" do
    field :token, :string
    field :platform, :string
    field :device_name, :string

    belongs_to :user, Slackex.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @required [:user_id, :token, :platform]
  @optional [:device_name]

  def changeset(device_token, attrs) do
    device_token
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:platform, ["fcm", "apns", "web_push"])
    |> validate_length(:platform, max: 10)
    |> validate_length(:device_name, max: 100)
    |> unique_constraint(:token)
    |> foreign_key_constraint(:user_id)
  end
end
