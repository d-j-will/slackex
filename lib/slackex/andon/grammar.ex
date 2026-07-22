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
    * `:correction` — the message opens a pull but the class is unknown or the
      sentence is missing; the relay posts an in-thread correction (never a
      modal) and sends NO event.
    * `:not_a_pull` — ordinary channel traffic; `pull:` was not the exact
      token at message start (v1 reads the spec literally — `Pull:` and a
      mid-message keyword are both ordinary traffic).

  The optional `/pull` slash-command adapter (fixture `identical_event_rule`)
  is deferred in v1; only the text grammar ships, so there is no second input
  method to compare for byte-equality. See the conformance PROVENANCE note.
  """

  @classes ~w(defect delay burden confusion)

  @doc "Returns the recognised pull classes."
  @spec classes() :: [String.t()]
  def classes, do: @classes

  @typedoc "The outcome of parsing a message against the pull grammar."
  @type outcome :: {:pull, String.t(), String.t()} | :correction | :not_a_pull

  @doc """
  Parses message text against the pull grammar. See the moduledoc for the
  outcome contract.
  """
  @spec parse(String.t()) :: outcome()
  def parse("pull: " <> rest), do: classify(rest)
  def parse(_text), do: :not_a_pull

  defp classify(rest) do
    case String.split(rest, " ", parts: 2) do
      [class, sentence] when class in @classes ->
        # A blank sentence (empty or whitespace-only, e.g. "pull: defect   ")
        # is a missing sentence, not a pull with an empty description. Only the
        # emptiness check trims — the stored sentence stays verbatim.
        if blank?(sentence), do: :correction, else: {:pull, class, sentence}

      _ ->
        # Opens a pull (`pull: ` prefix) but the class is unknown or the
        # sentence is missing — a correction, never an event.
        :correction
    end
  end

  defp blank?(sentence), do: String.trim(sentence) == ""
end
