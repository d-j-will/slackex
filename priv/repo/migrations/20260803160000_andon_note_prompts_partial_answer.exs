defmodule Slackex.Repo.Migrations.AndonNotePromptsPartialAnswer do
  use Ecto.Migration

  def change do
    # A half-answer used to be thrown away. Someone who typed
    # `cause: dogfooding` had the cause parsed out of their message, dropped
    # because the note half was empty, and was then asked to send BOTH halves
    # again — so they retyped the cause they had just given. Observed three
    # times in one afternoon on 2026-08-03, which is ADR-0019's own revisit
    # condition ("the prose is still not carried between messages") firing.
    #
    # Two nullable columns, one per half. They hold at most one message's
    # worth of answer, for the life of an arming that is already bounded by
    # `spent_at` — no new expiry, and nothing is remembered after the note
    # lands.
    alter table(:andon_note_prompts) do
      add :partial_note, :text
      add :partial_cause, :text
    end
  end
end
