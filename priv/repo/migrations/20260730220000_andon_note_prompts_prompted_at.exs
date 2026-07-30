defmodule Slackex.Repo.Migrations.AndonNotePromptsPromptedAt do
  use Ecto.Migration

  def change do
    # The arming now survives an attempt that recorded nothing (andon ENG-74,
    # ADR-0019), so the corrective prompt needs its own bound: without one,
    # every later message the holder sends in that thread would earn another
    # "I need the cause". The question is asked once and the correction once;
    # after that the relay stays silent and keeps listening.
    alter table(:andon_note_prompts) do
      add :prompted_at, :utc_datetime_usec
    end
  end
end
