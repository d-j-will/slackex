defmodule Slackex.Andon.Mirror do
  @moduledoc """
  Renders the channel status mirror (C6, mirror half) as one compact block of
  plain text. Person-blind by the guarantees: it shows subjects, classes, and
  ages — never people. The `update_mirror` payload is already person-free
  (holds, unbound pulls, oldest-open by thread/age); this module only formats.
  """

  @doc "Renders the `mirror` map from an `update_mirror` command to plain text."
  @spec render(map()) :: String.t()
  def render(mirror) do
    holds = Map.get(mirror, "active_holds", [])
    unbound = Map.get(mirror, "unbound_pulls", [])
    oldest = Map.get(mirror, "oldest_open")

    [
      "*Andon status*",
      holds_line(holds),
      hold_bullets(holds),
      unbound_line(unbound),
      oldest_line(oldest)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n")
  end

  defp holds_line([]), do: "Holds: none"
  defp holds_line(holds), do: "Holds (#{length(holds)}):"

  defp hold_bullets([]), do: nil

  defp hold_bullets(holds) do
    for hold <- holds do
      subject = get_in(hold, ["subject", "external_id"]) || "unbound subject"
      class = Map.get(hold, "class", "")
      age = age(Map.get(hold, "held_since"))
      escalated = if Map.get(hold, "escalated"), do: " · escalated", else: ""
      "• #{subject} #{class} · held #{age}#{escalated}"
    end
  end

  defp unbound_line([]), do: nil

  defp unbound_line(unbound) do
    n = length(unbound)
    "Unbound: #{n} pull#{if n == 1, do: "", else: "s"} awaiting a subject"
  end

  defp oldest_line(nil), do: nil
  defp oldest_line(oldest), do: "Oldest open: #{age(Map.get(oldest, "since"))}"

  # A coarse, person-free age label from an ISO8601 timestamp.
  defp age(nil), do: "?"

  defp age(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, then, _} -> humanize(DateTime.diff(DateTime.utc_now(), then, :second))
      _ -> "?"
    end
  end

  defp humanize(seconds) when seconds < 60, do: "just now"
  defp humanize(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp humanize(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)}h"
  defp humanize(seconds), do: "#{div(seconds, 86_400)}d"
end
