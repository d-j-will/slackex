defmodule Slackex.Andon.TaughtPhrasesTest do
  @moduledoc """
  Everything the bot tells a person to type, the parser must accept.

  Four of this project's nine bug cards are one shape: the bot names a phrase,
  someone types it or very nearly it, and the parser drops it in silence —
  ENG-51 (a phone capitalised `Pull:`), ENG-72 (`defect dogfooding`), ENG-75
  (the note kept the separator the bot taught), ENG-78 (the correction invited
  a reply it then swallowed). None of them was a hard bug to write a test for.
  What was missing is that nothing connected the two halves: the copy lives as
  private functions in `Slackex.Andon`, the grammar lives in `Grammar` and
  `Phrases`, and no test ever crossed between them.

  This file is that crossing, and it is a **ratchet rather than a feature
  test**: teaching a new phrase without classifying it here fails the suite.

  It cannot catch everything, and the moduledoc should not pretend otherwise.
  It asserts that a taught phrase, typed *as taught*, is understood — including
  in the case forms a phone produces. It does **not** assert what happens to a
  taught phrase with a stray word after it; that gap is real, measured, and
  carded, and the table at the bottom of this file records which cells are
  covered so the next person can see the shape of what is not.
  """
  use ExUnit.Case, async: true

  alias Slackex.Andon.Grammar
  alias Slackex.Andon.Phrases

  # Every in-thread phrase the bot teaches, and where it teaches it. A phrase
  # earns its place here by appearing in copy a person reads — not by existing
  # in the parser. The parser accepting something nobody is told about is not
  # this file's business; the reverse is.
  @taught_in_thread [
    # taught by `dri_phrases/0`, on every receipt
    "ack",
    "heard",
    # taught by `puller_confirmation/1`, on every bound pull
    "resolved",
    # taught by `help_text/0`
    "withdraw",
    # taught by the question at release (ENG-60)
    "no note",
    # taught by `class_question_text/0` and the ENG-72 correction
    "defect",
    "delay",
    "burden",
    "confusion"
  ]

  # Accepted but not taught anywhere — kept working because people type them
  # (ADR: the ack list is slackex's own choice), and deliberately not asserted
  # as taught copy.
  @accepted_not_taught ["seen", "on it", "engage", "nothing to note"]

  # Taught as a *prefix*, meaningless alone: the person types it and then their
  # own words. Separated from the bare phrases because "does it parse" is a
  # different question — a bare `note:` is not an act, and asserting it were
  # one would encode the wrong rule. Each is exercised with content below.
  #
  # The ratchet found all three of these. They were taught in copy and absent
  # from the first version of this file, which is the failure mode in miniature.
  @taught_prefixes ["pull:", "note:", "cause:"]

  # Backticked tokens in `Slackex.Andon` that are code, not copy: module and
  # function references, event and command names, atoms, formats. Kept as an
  # explicit list rather than a clever regex, because the whole point is that
  # a token nobody has classified fails the build.
  @not_a_phrase ~w(action class ctx thread)

  describe "a phrase the bot teaches is a phrase the parser accepts" do
    test "every taught in-thread phrase parses to an intent, never silence" do
      for phrase <- @taught_in_thread do
        assert Phrases.parse(phrase) != :none,
               "the bot teaches `#{phrase}` and the parser answers :none — " <>
                 "that is ENG-72's shape: taught, typed, dropped"
      end
    end

    test "and still parses when a phone capitalises it (ADR-0014)" do
      # The bug that started this: `Pull:` from a phone keyboard was ordinary
      # traffic. Case is a transformation the platform applies without asking,
      # so every taught phrase has to survive it.
      for phrase <- @taught_in_thread,
          variant <- [String.capitalize(phrase), String.upcase(phrase)] do
        assert Phrases.parse(variant) != :none,
               "`#{variant}` is `#{phrase}` as a phone would send it, and it was dropped"
      end
    end

    test "the taught pull keyword opens a pull in every case form" do
      for keyword <- ["pull:", "Pull:", "PULL:"] do
        assert {:pull, _class, _sentence} = Grammar.parse(keyword <> " I'm a bit stuck here")
      end
    end

    test "an attempt at the keyword is never ordinary traffic, however malformed" do
      # ADR-0014 decision 3. `pull:` alone and the missing space are the two
      # shapes that used to fall through to silence.
      for attempt <- ["pull:", "Pull:", "pull:defect the build is red"] do
        refute Grammar.parse(attempt) == :not_a_pull,
               "`#{attempt}` opens with the keyword and was treated as chatter"
      end
    end

    test "every taught prefix is understood when a person adds their own words" do
      # A prefix is taught as `note: <what it was>`; the placeholder is the
      # person's own text, so the assertion is that the prefix plus *anything*
      # is an act rather than chatter.
      assert {:pull, _class, "the build is red"} = Grammar.parse("pull: the build is red")

      assert {:closure_note_needs_cause, "it was the migration"} =
               Phrases.parse("note: it was the migration")

      # `cause:` is taught only as the second half of the note shape, never
      # alone — pinned here so that stays true rather than being assumed.
      assert {:closure_note, _note, "deploy order"} =
               Phrases.parse("note: it was the migration / cause: deploy order")
    end

    test "the note shape the bot teaches round-trips with both halves clean" do
      # ENG-75: the taught shape is `note: <what it was> / cause: <why>`, and
      # the separator the prompt tells you to type used to land inside the note.
      assert {:closure_note, note, cause} =
               Phrases.parse("note: the migration had not run / cause: deploy order")

      assert note == "the migration had not run"
      assert cause == "deploy order"

      # The same shape typed as a prompted answer, with no prefix (ENG-60).
      assert {:closure_note, ^note, ^cause} =
               Phrases.answer("the migration had not run / cause: deploy order")
    end
  end

  describe "the ratchet" do
    test "every phrase-shaped token in the bot's copy is classified here" do
      source = File.read!(Path.join(File.cwd!(), "lib/slackex/andon.ex"))

      unclassified =
        ~r/`([^`]+)`/
        |> Regex.scan(source, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.filter(&phrase_shaped?/1)
        |> Enum.reject(
          &(&1 in @taught_in_thread or &1 in @accepted_not_taught or
              &1 in @taught_prefixes or &1 in @not_a_phrase)
        )

      assert unclassified == [],
             """
             New backticked token(s) in the bot's copy that nobody has classified:

               #{Enum.join(unclassified, "\n  ")}

             If a person is meant to type it, add it to @taught_in_thread — the
             tests above will then hold the parser to it. If it is a code or
             event reference, add it to @not_a_phrase. Silence here is how
             ENG-51, ENG-72 and ENG-75 each shipped.
             """
    end
  end

  # A token a person could plausibly be told to type: lowercase words and
  # spaces only. Everything with a slash, dot, underscore, brace, quote, angle
  # bracket, digit or capital is a code reference, a format, or a placeholder
  # shape rather than a literal to type.
  defp phrase_shaped?(token) do
    Regex.match?(~r/^[a-z][a-z ]*:?$/, token)
  end

  # ## Coverage, stated rather than implied
  #
  # | Typed as…                    | Covered here | Behaviour today            |
  # |------------------------------|--------------|----------------------------|
  # | the taught phrase exactly    | yes          | parses                     |
  # | phone-capitalised            | yes          | parses (ADR-0014)          |
  # | the taught `note:` composite | yes          | both halves clean (ENG-75) |
  # | keyword alone / no space     | yes          | correction, not silence    |
  # | a class word + a stray word  | **no**       | correction (ENG-72)        |
  # | any OTHER taught phrase      | **no**       | **silence** — see ENG-81   |
  #   + a stray word
  #
  # The last row is why this file exists and is the reason not to read a green
  # run as "the class is closed". `resolved now`, `ack will do`, `heard you`
  # and `no note thanks` all parse to `:none` today. ENG-72 fixed exactly one
  # of the four phrase families; the other three were never looked at.
end
