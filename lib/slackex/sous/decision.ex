defmodule Slackex.Sous.Decision do
  @moduledoc """
  Kind-specific detail for a `:decision` work item (1:1). Plaintext fields by
  deliberate Slice A choice — see ADR-001.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "decisions" do
    field :work_item_id, :integer, primary_key: true
    field :what, :string
    field :why, :string
    field :next, :string
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [:work_item_id, :what, :why, :next])
    |> validate_required([:work_item_id, :what])
  end
end
