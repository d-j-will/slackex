defmodule Slackex.Links.LinkPreview do
  @moduledoc """
  Schema for cached link preview metadata extracted from URLs in messages.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(pending fetched blocked)

  schema "link_previews" do
    field :message_id, :integer
    field :url, :string
    field :title, :string
    field :description, :string
    field :site_name, :string
    field :image_url, :string
    field :favicon_url, :string
    field :status, :string, default: "pending"
    field :blocked_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(preview, attrs) do
    preview
    |> cast(attrs, [
      :message_id,
      :url,
      :title,
      :description,
      :site_name,
      :image_url,
      :favicon_url,
      :status,
      :blocked_reason
    ])
    |> validate_required([:message_id, :url])
    |> validate_inclusion(:status, @statuses)
    |> truncate_field(:title, 200)
    |> truncate_field(:description, 500)
    |> truncate_field(:site_name, 100)
    |> unique_constraint([:message_id, :url])
  end

  defp truncate_field(changeset, field, max_length) do
    case get_change(changeset, field) do
      nil -> changeset
      value -> put_change(changeset, field, String.slice(value, 0, max_length))
    end
  end
end
