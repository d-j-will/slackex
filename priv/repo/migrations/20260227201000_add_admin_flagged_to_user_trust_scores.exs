defmodule Slackex.Repo.Migrations.AddAdminFlaggedToUserTrustScores do
  use Ecto.Migration

  def change do
    alter table(:user_trust_scores) do
      add :admin_flagged, :boolean, default: false, null: false
      add :admin_flagged_at, :utc_datetime_usec
    end
  end
end
