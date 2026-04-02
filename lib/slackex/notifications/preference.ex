defmodule Slackex.Notifications.Preference do
  @moduledoc "Notification preference per user per channel. NULL channel_id = global default."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Slackex.Repo

  @valid_levels ~w(all mentions nothing)

  schema "notification_preferences" do
    field :level, :string, default: "all"
    belongs_to :user, Slackex.Accounts.User
    belongs_to :channel, Slackex.Chat.Channel
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:user_id, :channel_id, :level])
    |> validate_required([:user_id, :level])
    |> validate_inclusion(:level, @valid_levels)
  end

  def resolve_level(user_id, nil) do
    get_global_default_level(user_id)
  rescue
    _ -> "all"
  end

  def resolve_level(user_id, channel_id) do
    case get_by_channel(user_id, channel_id) do
      %{level: level} -> level
      nil -> get_global_default_level(user_id)
    end
  rescue
    _ -> "all"
  end

  def set_preference(user_id, channel_id, level) do
    case Repo.get_by(__MODULE__, user_id: user_id, channel_id: channel_id) do
      nil -> %__MODULE__{user_id: user_id, channel_id: channel_id}
      existing -> existing
    end
    |> changeset(%{level: level})
    |> Repo.insert_or_update()
  end

  def set_global_default(user_id, level) do
    case get_global_default(user_id) do
      nil -> %__MODULE__{user_id: user_id, channel_id: nil}
      existing -> existing
    end
    |> changeset(%{level: level})
    |> Repo.insert_or_update()
  end

  def create_default_for_user(user_id) do
    %__MODULE__{}
    |> changeset(%{user_id: user_id, channel_id: nil, level: "all"})
    |> Repo.insert(on_conflict: :nothing)
  end

  defp get_by_channel(user_id, channel_id) do
    __MODULE__
    |> where([p], p.user_id == ^user_id and p.channel_id == ^channel_id)
    |> Repo.one()
  end

  defp get_global_default(user_id) do
    __MODULE__
    |> where([p], p.user_id == ^user_id and is_nil(p.channel_id))
    |> Repo.one()
  end

  defp get_global_default_level(user_id) do
    __MODULE__
    |> where([p], p.user_id == ^user_id and is_nil(p.channel_id))
    |> select([p], p.level)
    |> Repo.one() || "all"
  end
end
