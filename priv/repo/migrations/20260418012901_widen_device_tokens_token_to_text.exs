defmodule Slackex.Repo.Migrations.WidenDeviceTokensTokenToText do
  use Ecto.Migration

  # Web Push subscription JSON (endpoint + p256dh + auth) is ~400-500 bytes,
  # exceeding the implicit varchar(255) of `:string`. Inserts were crashing
  # with Postgrex 22001 string_data_right_truncation, killing the LiveView
  # before the device token could be persisted. text has no length cap and
  # the existing btree unique index handles values well under the ~2700-byte
  # per-entry limit.
  def change do
    alter table(:device_tokens) do
      modify :token, :text, from: :string
    end
  end
end
