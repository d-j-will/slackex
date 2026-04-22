defmodule SlackexWeb.ChatLive.Catchup do
  @moduledoc """
  Pure helpers that turn a `Slackex.Notifications.CatchupServer` payload
  into LiveView assign updates and a user-visible flash summary.

  Kept side-effect-free so it is trivial to test and to call from
  `mount/3` without coupling to socket plumbing.
  """

  @type unread_counts :: %{
          channel_counts: %{integer() => non_neg_integer()},
          dm_counts: %{integer() => non_neg_integer()}
        }

  @type catchup_payload :: %{
          channels: [
            %{
              channel_id: integer(),
              unread_count: non_neg_integer(),
              channel_name: String.t(),
              channel_slug: String.t(),
              recent_messages: [map()]
            }
          ],
          timestamp: DateTime.t()
        }

  @doc """
  Overlays the per-channel unread counts from a catchup payload onto the
  map already built by `Chat.batch_unread_counts/1`. Channels not present
  in the payload are left alone. `dm_counts` are not touched — the DM
  path has its own catchup in a future task.
  """
  @spec merge_unread(unread_counts(), catchup_payload()) :: unread_counts()
  def merge_unread(existing, %{channels: channels}) do
    channel_counts =
      Enum.reduce(channels, existing.channel_counts, fn
        %{channel_id: id, unread_count: n}, acc -> Map.put(acc, id, n)
      end)

    %{existing | channel_counts: channel_counts}
  end

  @doc """
  Produces a flash-friendly summary of how many messages were missed while
  the user's LiveView was disconnected. Returns `nil` when nothing was
  missed so the caller can skip putting a flash entirely.
  """
  @spec summary(catchup_payload()) :: String.t() | nil
  def summary(%{channels: channels}) do
    total = Enum.reduce(channels, 0, fn c, acc -> acc + c.unread_count end)

    case total do
      0 -> nil
      1 -> "1 new message while you were away"
      n -> "#{n} new messages while you were away"
    end
  end
end
