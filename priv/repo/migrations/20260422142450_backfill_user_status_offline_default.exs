defmodule Slackex.Repo.Migrations.BackfillUserStatusOfflineDefault do
  use Ecto.Migration

  # The `users.status` field is a free-form custom status message, not a
  # presence indicator. Its previous default ("offline") rendered next to
  # the green online dot, contradicting it. Switch the default to empty
  # and clear pre-existing default rows so the conditional render hides
  # the field for users who never set a custom status.

  def up do
    execute "ALTER TABLE users ALTER COLUMN status SET DEFAULT ''"
    execute "UPDATE users SET status = '' WHERE status = 'offline'"
  end

  def down do
    execute "ALTER TABLE users ALTER COLUMN status SET DEFAULT 'offline'"
    execute "UPDATE users SET status = 'offline' WHERE status = ''"
  end
end
