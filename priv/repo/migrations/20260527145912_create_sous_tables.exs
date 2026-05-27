defmodule Slackex.Repo.Migrations.CreateSousTables do
  use Ecto.Migration

  def change do
    create table(:work_items, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :kind, :string, null: false
      add :state, :string, null: false
      add :title, :text, null: false
      add :facet_text, :text
      add :attention, :string, null: false, default: "watch"
      add :people, :map, null: false, default: %{}
      add :channel_id, references(:channels, on_delete: :delete_all)
      add :thread_root_message_id, :bigint
      # No FK on card_message_id: messages are written async via the cache,
      # so a hard constraint could race the batch writer (ADR-002).
      add :card_message_id, :bigint
      add :moved_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:work_items, [:state])
    create index(:work_items, [:channel_id])
    create index(:work_items, [:card_message_id])

    create table(:decisions, primary_key: false) do
      add :work_item_id,
          references(:work_items, on_delete: :delete_all, type: :bigint),
          primary_key: true

      add :what, :text, null: false
      add :why, :text
      add :next, :text
    end

    create table(:work_item_events, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :work_item_id, references(:work_items, on_delete: :delete_all, type: :bigint),
        null: false

      add :type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :actor_user_id, references(:users, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime_usec, null: false
    end

    # Ordered replay of a work item's log.
    create index(:work_item_events, [:work_item_id, :id])
  end
end
