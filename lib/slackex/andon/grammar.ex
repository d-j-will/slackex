defmodule Slackex.Andon.Grammar do
  @moduledoc """
  The canonical `pull:` grammar (C1), the relay's half of parsing.

  A pull is the exact token `pull:` at the very start of a message, followed
  by a class and a one-sentence description. This module is pure: it maps
  message text to a parse outcome and never touches the service, the log, or
  Slack. The conformance claim (`Slackex.Andon.GrammarTest`) drives every
  `grammar_cases` entry in the vendored fixture through `parse/1`.

  Outcomes:

    * `{:pull, class, sentence}` — a well-formed pull; the relay POSTs a
      `pull_created` domain event with this class and verbatim sentence.
      `class` is nil for the bare cord (ENG-45, ADR-0016): a first word that
      is not a class word is SENTENCE, not error — "pull: I'm a bit stuck"
      is the purest pull there is, created classless with the whole text
      after the keyword kept verbatim, would-be class word included. The
      class is settled afterwards in-thread; the grammar never gatekeeps.
    * `:correction` — the message **opens** a pull but does not complete one:
      no sentence to take — the keyword alone, a class word with nothing
      after it, or no space after the colon. The relay posts an in-thread
      correction (never a modal) and sends NO event.
    * `:not_a_pull` — ordinary channel traffic; the keyword was not at message
      start. Talk *about* pulling ("we could pull: defect this later") stays
      ordinary traffic, which is what keeps a channel discussing the andon out
      of the log.

  The keyword and the class are matched **case-insensitively**; the sentence is
  stored verbatim, case and all. A phone capitalises the first word of a
  message, so an exact-token reading meant the canonical grammar failed by
  default on the device C1 chose it to survive — and failed silently, which was
  the worse half. ADR-0014 has the reasoning; the spec constrains only that the
  keyword is recognised at message start, and is silent on case.

  Opening a pull and completing one are therefore different things, and the
  gap between them is always answered. Every malformed attempt earns the same
  correction rather than the better-formed ones getting help and the worse ones
  getting nothing.

  The optional `/pull` slash-command adapter (fixture `identical_event_rule`)
  is deferred in v1; only the text grammar ships, so there is no second input
  method to compare for byte-equality. See the conformance PROVENANCE note.
  """

  @classes ~w(defect delay burden confusion)

  @keyword_size byte_size("pull:")

  @doc "Returns the recognised pull classes."
  @spec classes() :: [String.t()]
  def classes, do: @classes

  @typedoc "The outcome of parsing a message against the pull grammar."
  @type outcome :: {:pull, String.t() | nil, String.t()} | :correction | :not_a_pull

  @doc """
  Parses message text against the pull grammar. See the moduledoc for the
  outcome contract.
  """
  @spec parse(String.t()) :: outcome()
  def parse(text) when is_binary(text) do
    if opens_pull?(text) do
      text
      |> binary_part(@keyword_size, byte_size(text) - @keyword_size)
      |> classify()
    else
      :not_a_pull
    end
  end

  # The keyword's five bytes, compared without case. Done bytewise rather than
  # by downcasing the message: `String.downcase/1` can change a string's byte
  # length, and the offset the rest is cut at has to stay true to the original.
  defp opens_pull?(<<p, u, l1, l2, ?:, _rest::binary>>) do
    lower(p) == ?p and lower(u) == ?u and lower(l1) == ?l and lower(l2) == ?l
  end

  defp opens_pull?(_text), do: false

  defp lower(char) when char in ?A..?Z, do: char + 32
  defp lower(char), do: char

  # One space separates the keyword from the class. Anything else — `pull:` on
  # its own, or `pull:defect ...` — opened a pull without completing one, and
  # is corrected rather than ignored. Case is the keyboard's doing and we
  # absorb it; a missing space is the person's, and telling them is the help.
  defp classify(" " <> rest) do
    case String.split(rest, " ", parts: 2) do
      [class, sentence] -> classify_pair(class, sentence, rest)
      [word] -> classify_word(word)
    end
  end

  defp classify(_rest), do: :correction

  # A blank sentence (empty or whitespace-only, e.g. "pull: defect   ") is a
  # missing sentence, not a pull with an empty description. Only the emptiness
  # check trims — the stored sentence stays verbatim, and so does its case.
  # An unknown first word is not a mistake to correct: it is the sentence's
  # first word, and the whole of `rest` posts as a classless pull (ENG-45).
  defp classify_pair(class, sentence, rest) do
    cond do
      known_class?(class) and not blank?(sentence) -> {:pull, String.downcase(class), sentence}
      known_class?(class) -> :correction
      not blank?(rest) -> {:pull, nil, rest}
      true -> :correction
    end
  end

  # One word after the keyword. A class word alone has no sentence to take;
  # any other single word IS the sentence — "pull: help" is a bare cord, not
  # a mistake.
  defp classify_word(word) do
    if known_class?(word) or blank?(word),
      do: :correction,
      else: {:pull, nil, word}
  end

  defp known_class?(class), do: String.downcase(class) in @classes

  defp blank?(sentence), do: String.trim(sentence) == ""
end
