defmodule Slackex.Repo.Migrations.CreateAndonNotePrompts do
  use Ecto.Migration

  def change do
    # The question asked at release (andon ENG-60 / ADR-0017). The service
    # names the pull and its holder; this row is what lets the holder answer
    # in plain words instead of a remembered grammar — their next message in
    # the thread is taken as the answer while the row is unspent.
    #
    # Durable rather than in-memory on purpose: a deploy between the question
    # and the answer must not silently swallow the reply, and the pull id
    # outlives the arming — a `note:` typed later in the thread still needs it
    # to address the right closed pull.
    create table(:andon_note_prompts) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      # The message id rooting the pull's thread.
      add :thread_id, :bigint, null: false
      # The service's pull id, echoed back on the answer so a thread holding
      # two closed pulls still addresses the right one.
      add :pull_id, :text, null: false
      # Whose reply binds: only the person the question was addressed to.
      add :holder_token, :text, null: false
      # Set when the arming is used up. Armed once — never re-armed, never
      # re-asked; the friction budget is one question.
      add :spent_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # One question per pull, so a redelivered release cannot re-arm it.
    create unique_index(:andon_note_prompts, [:pull_id])
    # The lookup a reply performs: the thread's most recent question.
    create index(:andon_note_prompts, [:channel_id, :thread_id])
  end
end
