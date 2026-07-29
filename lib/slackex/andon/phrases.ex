defmodule Slackex.Andon.Phrases do
  @moduledoc """
  The small vocabulary a person types inside a pull's thread to act on it
  (v1). Pure text → intent mapping; the caller turns an intent into the
  matching domain event.

  These are phrases, not affordances. An affordance is something a surface
  *offers* — a button on the hold card, an editable status message, the
  label+comment a tracker gives you. A word you have to already know to type
  offers nothing by itself; what makes it usable is the bot teaching it in
  the thread. Keeping the two apart is why the card's buttons are affordances
  and this module is a vocabulary.

  Recognised only as the exact phrase (not embedded in prose), mirroring the
  anchored issue-key grammar:

    * `ack` | `heard` | `seen` | `on it` | `engage` → `:ack`
    * `resolved`  → `:witness_close`     (the witness's message is the release)
    * `withdraw`  → `:withdraw`          (the puller drops an unbound pull)
    * `note: <t>` + `cause: <c>` → `{:closure_note, t, c}` (after release)
    * `<KEY>`     → `{:subject, KEY}`    (the puller answers the subject ask)
    * `defect` | `delay` | `burden` | `confusion` → `{:class, word}`
      (anyone answers the class question a bare pull was asked — ENG-45)

  A closure note carries two things: what was seen, and the writer's best
  guess at the cause. The guess is what nobody can reconstruct weeks later,
  and keeping it apart is what lets the retro notice the same cause twice, so
  the service refuses a note without one. Put `cause:` on its own line
  (Shift-Enter) or at the end of the line; a note typed without it comes back
  as `{:closure_note_needs_cause, note}` and the bot asks for the cause in
  the thread rather than logging half a note.

  Acknowledgement takes any of five phrases because the friction bar for
  answering a pull is "no harder than typing a grumble in a channel", and
  `ack` is not a word anyone types unprompted — the kitchen-brigade "heard"
  is. The cheap one-word answer is what makes silence audible, so the relay
  accepts the ones people actually type. Which words those are is a slackex
  decision, not a contract one: the service only ever receives `ack`, and
  another relay is free to teach different words (ADR-0002).

  A bare phrase must be the whole (trimmed) message, ignoring case and a
  trailing `.` or `!` — `heard!` acts, "I heard the build was red" is
  ordinary thread chatter. That whole-message rule is the only guard, and it
  is doing more work now that the phrases are common words. `note:` is a prefix followed
  by non-empty text. The subject key matches Linear's `ENG-123` form
  (ADR-0003), anchored end to end.

  `closed_without_puller` (the DRI closing in the puller's absence) has no
  way to invoke it in v1 — no phrase and no button, deferred. A `resolved` typed by someone the service does
  not treat as the witness is refused (403) and surfaced as an in-thread note,
  rather than the relay guessing the closed-without-puller case.

  Anything else is `:none` — ordinary thread traffic, no event.
  """

  # ADR-0003 subject key grammar (Linear first): a registered team key.
  @issue_key ~r/^[A-Z][A-Z0-9]*-\d+$/

  # What a person types to say "heard, I'm on it". See the moduledoc for why
  # there are five of them and why the list is slackex's to choose.
  @ack_phrases ["ack", "heard", "seen", "on it", "engage"]

  # The class question's answer key (ENG-45). These are the taxonomy's own
  # words rather than slackex-chosen synonyms because the bot's question
  # teaches them in the same message — nobody is expected to know them cold.
  @class_words ["defect", "delay", "burden", "confusion"]

  # The cause-guess marker, preferred on its own line (see split_cause/1).
  @cause_line ~r/^[ \t]*cause:/im
  @cause_inline ~r/cause:/i

  @typedoc "The intent parsed from an in-thread message."
  @type intent ::
          :ack
          | :witness_close
          | :withdraw
          | {:closure_note, String.t(), String.t()}
          | {:closure_note_needs_cause, String.t()}
          | {:subject, String.t()}
          | {:class, String.t()}
          | :none

  @doc "Parses an in-thread message into a lifecycle intent. See the moduledoc."
  @spec parse(String.t()) :: intent()
  def parse(text) when is_binary(text) do
    trimmed = String.trim(text)
    # Bare words and the `note:` prefix are case-insensitive (2026-07-24 field
    # finding — `Resolved`/`ACK` should act). Issue keys stay case-sensitive:
    # their grammar is uppercase (`ENG-123`), so they match on `trimmed`.
    lower = trimmed |> String.downcase() |> String.trim_trailing(".") |> String.trim_trailing("!")

    cond do
      lower in @ack_phrases -> :ack
      lower == "resolved" -> :witness_close
      lower == "withdraw" -> :withdraw
      lower in @class_words -> {:class, lower}
      String.starts_with?(lower, "note:") -> closure_note(trimmed)
      Regex.match?(@issue_key, trimmed) -> {:subject, trimmed}
      true -> :none
    end
  end

  # Strip the (case-insensitive) 5-byte "note:" prefix, keeping the note text
  # verbatim — only called when the trimmed message starts with the prefix.
  defp closure_note(<<_prefix::binary-size(5), rest::binary>>) do
    {note, cause} = split_cause(rest)

    case {String.trim(note), cause} do
      {"", _} -> :none
      {note, nil} -> {:closure_note_needs_cause, note}
      {note, cause} -> {:closure_note, note, cause}
    end
  end

  # `cause:` on its own line is the shape the bot teaches, and it cannot be
  # tripped by "root cause:" in the middle of a sentence. A one-liner still
  # works: with no line-anchored marker the LAST inline one wins, so
  # "fixed the root cause: db not reset" still lands the cause — at the price
  # of a word off the end of the note, which beats losing the cause.
  defp split_cause(rest) do
    case Regex.scan(@cause_line, rest, return: :index) do
      [[span | _] | _] -> cut(rest, span)
      [] -> split_inline(rest)
    end
  end

  defp split_inline(rest) do
    case Regex.scan(@cause_inline, rest, return: :index) do
      [] -> {rest, nil}
      matches -> matches |> List.last() |> hd() |> then(&cut(rest, &1))
    end
  end

  defp cut(text, {start, length}) do
    tail = binary_part(text, start + length, byte_size(text) - start - length)

    case String.trim(tail) do
      "" -> {binary_part(text, 0, start), nil}
      cause -> {binary_part(text, 0, start), cause}
    end
  end
end
