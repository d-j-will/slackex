defmodule Slackex.Factory.Event do
  @moduledoc """
  Append-only audit log for factory pipeline runs.
  Each state transition and progress update is recorded as an event.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_events" do
    field :event_type, :string
    field :from_status, :string
    field :to_status, :string
    field :message, :string
    field :metadata, :map

    belongs_to :factory_run, Slackex.Factory.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:factory_run_id, :event_type, :from_status, :to_status, :message, :metadata])
    |> validate_required([:factory_run_id, :event_type])
    |> validate_inclusion(:event_type, ~w(status_change progress error))
    |> foreign_key_constraint(:factory_run_id)
  end
end
