defmodule Slackex.Chat.Permissions do
  @moduledoc """
  Role-based authorization for chat actions.

  Role hierarchy:

  | Role   | Level | send_message | read_messages | manage_channel | delete_channel |
  |--------|-------|:---:|:---:|:---:|:---:|
  | owner  |   4   | yes | yes | yes | yes |
  | admin  |   3   | yes | yes | yes | no  |
  | member |   2   | yes | yes | no  | no  |
  | viewer |   1   | no  | yes | no  | no  |
  | nil    |   0   | no  | no  | no  | no  |
  """

  @role_levels %{
    "owner" => 4,
    "admin" => 3,
    "member" => 2,
    "viewer" => 1,
    nil => 0
  }

  # Minimum role level required for each action
  @action_min_level %{
    send_message: 2,
    read_messages: 1,
    manage_channel: 3,
    delete_channel: 4,
    edit_own_message: 2,
    delete_own_message: 2,
    delete_any_message: 3
  }

  @spec can?(String.t() | nil, atom()) :: boolean()
  def can?(role, action) do
    role_level = Map.get(@role_levels, role, 0)
    required = Map.get(@action_min_level, action, :infinity)
    role_level >= required
  end
end
