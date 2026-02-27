defmodule Slackex.Repo.Migrations.AddEncryptedFieldsToDmRequestsAndAbuseReports do
  use Ecto.Migration

  def change do
    alter table(:dm_requests) do
      add :encrypted_preview_text, :binary
    end

    alter table(:abuse_reports) do
      add :encrypted_description, :binary
      add :encrypted_metadata, :binary
    end
  end
end
