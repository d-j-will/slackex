defmodule Slackex.Andon.Help do
  @moduledoc """
  Recognises someone asking what they can type. Pure text → boolean.

  A person sitting in an andon channel has no way to discover the one action
  the product is about; until now the answer was somebody explaining the
  syntax over their shoulder. `andon help` is the asked-for version of that.

  **Why the phrase is not `help`.** `help` is the word people reach for when
  they are stuck — "I need help", "I'm a bit stuck here, someone help". That
  is the bare cord, the purest pull there is. Answering it with a syntax list
  would hand a manual to someone asking for a person, so `help` on its own
  stays available to mean what people mean by it and the discovery phrase
  takes the `andon` prefix. The refusals in `Slackex.Andon.HelpTest` are the
  substance of this module; the match is the easy half.

  It lives apart from `Slackex.Andon.Grammar` on purpose. Grammar answers to
  contract C1 — the vendored conformance fixture drives every one of its cases
  through `parse/1`, and its outcomes are the ones the service knows about.
  Asking for help produces no domain event and crosses no seam; it is this
  relay's own courtesy, and another relay is free to offer none or to offer a
  button instead (ADR-0002). Keeping it out of Grammar keeps the contract
  module's outcome set exactly the contract's.

  It is also not a `Slackex.Andon.Phrases` intent: those are the vocabulary
  for acting on a pull from inside its thread, and each maps to an event.
  Help belongs to no pull, is typed anywhere, and logs nothing.
  """

  @phrase "andon help"

  # The trailing characters someone actually types when asking a question of a
  # bot. Mirrors the tolerance `Phrases` allows on its bare words.
  @punctuation [".", "!", "?"]

  @doc """
  True when the message is someone asking what they can type.

  The phrase must be the whole (trimmed) message, ignoring case and one
  trailing `.`, `!` or `?` — the same whole-message rule the bare lifecycle
  phrases use, and for the same reason: it is the only thing keeping a common
  word from firing on ordinary conversation about it.
  """
  @spec asked?(String.t()) :: boolean()
  def asked?(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.downcase()
    |> strip_punctuation()
    |> Kernel.==(@phrase)
  end

  defp strip_punctuation(text) do
    Enum.reduce(@punctuation, text, &String.trim_trailing(&2, &1))
  end
end
