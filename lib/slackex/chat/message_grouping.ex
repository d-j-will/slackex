defmodule Slackex.Chat.MessageGrouping do
  @moduledoc """
  Pure functions for annotating a list of messages with grouping and time-divider metadata.

  These annotations are display-only and are never persisted. They populate the virtual
  fields `grouped`, `show_divider`, and `divider_label` on `Slackex.Chat.Message`.

  ## Grouping rules

  A message is grouped (compact display, no avatar/name) when ALL of:
  - Same `sender_id` as the previous message
  - Within 5 minutes of the previous message's `inserted_at`
  - Previous message is not deleted (`deleted_at` is nil)
  - Current message is not a thread reply (`parent_message_id` is nil)

  ## Time divider rules

  A time divider is shown when there is a 30+ minute gap between consecutive messages.
  Label format:
  - Same day as today → "Today at 14:30"
  - Yesterday → "Yesterday at 09:15"
  - Older → "March 15 at 14:30"
  """

  alias Slackex.Chat.Message

  @group_window_seconds 5 * 60
  @divider_gap_seconds 30 * 60

  @doc """
  Annotates a list of `%Message{}` structs with `grouped`, `show_divider`, and
  `divider_label` virtual fields.

  The first message in the list is never grouped and never receives a divider.

  ## Options

  - `:today` — override the current date (a `Date`) used for divider label generation.
    Defaults to `Date.utc_today/0`. Useful in tests.
  """
  @spec annotate([Message.t()], keyword()) :: [Message.t()]
  def annotate(messages, opts \\ [])

  def annotate([], _opts), do: []

  def annotate([first | rest], opts) do
    today = Keyword.get(opts, :today, Date.utc_today())

    annotated_first = %{first | grouped: false, show_divider: false, divider_label: nil}

    {annotated_rest, _prev} =
      Enum.map_reduce(rest, annotated_first, fn msg, prev ->
        grouped = should_group?(msg, prev)
        {show_divider, divider_label} = compute_divider_info(msg, prev, today)

        annotated = %{
          msg
          | grouped: grouped,
            show_divider: show_divider,
            divider_label: divider_label
        }

        {annotated, annotated}
      end)

    [annotated_first | annotated_rest]
  end

  @doc """
  Returns `true` when `incoming_message` should be displayed in compact (grouped) form
  relative to `last_message`.

  Returns `false` when `last_message` is `nil` (i.e. no prior context is available).
  """
  @spec should_group?(Message.t(), Message.t() | nil) :: boolean()
  def should_group?(_incoming, nil), do: false

  def should_group?(incoming, last) do
    incoming.sender_id == last.sender_id and
      is_nil(Map.get(last, :deleted_at)) and
      is_nil(Map.get(incoming, :parent_message_id)) and
      within_group_window?(incoming.inserted_at, last.inserted_at)
  end

  @doc """
  Returns `{show_divider, divider_label}` for `incoming_message` relative to `last_message`.

  Returns `{false, nil}` when `last_message` is `nil`.

  ## Options

  - `:today` — override the current date (`Date`) for label generation. Defaults to
    `Date.utc_today/0`.
  """
  @spec divider_info(Message.t(), Message.t() | nil, keyword()) :: {boolean(), String.t() | nil}
  def divider_info(incoming, last, opts \\ [])

  def divider_info(_incoming, nil, _opts), do: {false, nil}

  def divider_info(incoming, last, opts) do
    today = Keyword.get(opts, :today, Date.utc_today())
    compute_divider_info(incoming, last, today)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp within_group_window?(incoming_ts, last_ts) do
    diff = DateTime.diff(incoming_ts, last_ts, :second)
    diff < @group_window_seconds
  end

  defp compute_divider_info(incoming, last, today) do
    gap_seconds = DateTime.diff(incoming.inserted_at, last.inserted_at, :second)

    if gap_seconds >= @divider_gap_seconds do
      label = format_divider_label(incoming.inserted_at, today)
      {true, label}
    else
      {false, nil}
    end
  end

  defp format_divider_label(ts, today) do
    msg_date = DateTime.to_date(ts)
    time_str = Calendar.strftime(ts, "%H:%M")

    cond do
      msg_date == today ->
        "Today at #{time_str}"

      msg_date == Date.add(today, -1) ->
        "Yesterday at #{time_str}"

      true ->
        date_str = Calendar.strftime(ts, "%B %-d")
        "#{date_str} at #{time_str}"
    end
  end
end
