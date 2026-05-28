defmodule Slackex.Sous.Viewer do
  @moduledoc """
  A role-lens. Data-driven (the set is configurable per team), seeded by the
  B1 migration. Viewers are IMMUTABLE in B1 (no delete / no rename) — invariant
  #11 in the Slice B1 spec; role management UI is B-later.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [order_by: 3]

  @primary_key {:id, :string, autogenerate: false}

  schema "viewers" do
    field :name, :string
    field :color, :string
    field :focus, {:array, :string}, default: []
    field :position, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Listing in switcher order."
  def order_by_position(query \\ __MODULE__), do: order_by(query, [v], asc: v.position)

  def changeset(viewer, attrs) do
    viewer
    |> cast(attrs, [:id, :name, :color, :focus, :position])
    |> validate_required([:id, :name, :color])
  end
end
