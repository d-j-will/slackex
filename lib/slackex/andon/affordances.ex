defmodule Slackex.Andon.Affordances do
  @moduledoc """
  Thread-lifecycle affordances (v1): the small vocabulary a person types
  inside a pull's thread to act on it. Pure text → intent mapping; the caller
  turns an intent into the matching domain event.

  Recognised only as the exact affordance (not embedded in prose), mirroring
  the anchored issue-key grammar:

    * `ack`       → `:ack`               (the DRI answers the first timer)
    * `resolved`  → `:witness_close`     (the witness's message is the release)
    * `withdraw`  → `:withdraw`          (the puller drops an unbound pull)
    * `note: <t>` → `{:closure_note, t}` (the DRI's note, after release)
    * `<KEY>`     → `{:subject, KEY}`    (the puller answers the subject ask)

  A bare word must be the whole (trimmed) message — `resolved` acts, but
  "resolved, finally" is ordinary thread chatter. `note:` is a prefix followed
  by non-empty text. The subject key matches Linear's `ENG-123` form
  (ADR-0003), anchored end to end.

  `closed_without_puller` (the DRI closing in the puller's absence) has NO
  affordance in v1 — deferred. A `resolved` typed by someone the service does
  not treat as the witness is refused (403) and surfaced as an in-thread note,
  rather than the relay guessing the closed-without-puller case.

  Anything else is `:none` — ordinary thread traffic, no event.
  """

  # ADR-0003 subject key grammar (Linear first): a registered team key.
  @issue_key ~r/^[A-Z][A-Z0-9]*-\d+$/

  @typedoc "The intent parsed from an in-thread message."
  @type intent ::
          :ack
          | :witness_close
          | :withdraw
          | {:closure_note, String.t()}
          | {:subject, String.t()}
          | :none

  @doc "Parses an in-thread message into a lifecycle intent. See the moduledoc."
  @spec parse(String.t()) :: intent()
  def parse(text) when is_binary(text) do
    trimmed = String.trim(text)
    # Bare words and the `note:` prefix are case-insensitive (2026-07-24 field
    # finding — `Resolved`/`ACK` should act). Issue keys stay case-sensitive:
    # their grammar is uppercase (`ENG-123`), so they match on `trimmed`.
    lower = String.downcase(trimmed)

    cond do
      lower == "ack" -> :ack
      lower == "resolved" -> :witness_close
      lower == "withdraw" -> :withdraw
      String.starts_with?(lower, "note:") -> closure_note(trimmed)
      Regex.match?(@issue_key, trimmed) -> {:subject, trimmed}
      true -> :none
    end
  end

  # Strip the (case-insensitive) 5-byte "note:" prefix, keeping the note text
  # verbatim — only called when the trimmed message starts with the prefix.
  defp closure_note(<<_prefix::binary-size(5), rest::binary>>) do
    case String.trim(rest) do
      "" -> :none
      note -> {:closure_note, note}
    end
  end
end
