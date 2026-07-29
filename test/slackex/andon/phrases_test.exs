defmodule Slackex.Andon.PhrasesTest do
  @moduledoc """
  The in-thread lifecycle vocabulary (v1). Bare-word phrases act only as
  the whole trimmed message; `note:` is a prefix; a subject key is anchored.
  """
  use ExUnit.Case, async: true

  alias Slackex.Andon.Phrases

  describe "bare words (whole message only)" do
    test "ack acknowledges" do
      assert Phrases.parse("ack") == :ack
      assert Phrases.parse("  ack  ") == :ack
    end

    test "resolved is the witness close" do
      assert Phrases.parse("resolved") == :witness_close
    end

    test "withdraw drops the pull" do
      assert Phrases.parse("withdraw") == :withdraw
    end

    test "a bare word embedded in prose is not a phrase" do
      assert Phrases.parse("resolved, finally") == :none
      assert Phrases.parse("please ack this") == :none
      assert Phrases.parse("ack the thing") == :none
    end

    test "a bare class word answers the class question (ENG-45)" do
      assert Phrases.parse("defect") == {:class, "defect"}
      assert Phrases.parse("delay") == {:class, "delay"}
      assert Phrases.parse("burden") == {:class, "burden"}
      assert Phrases.parse("confusion") == {:class, "confusion"}
    end

    test "a class word survives a phone keyboard (case + trailing punctuation)" do
      assert Phrases.parse("Defect.") == {:class, "defect"}
      assert Phrases.parse("BURDEN!") == {:class, "burden"}
    end

    test "a class word inside prose is chatter, not an answer" do
      assert Phrases.parse("the defect is in the parser") == :none
      assert Phrases.parse("what a burden") == :none
    end
  end

  describe "acknowledge phrases (what a person actually types)" do
    test "the cheap one-word answers all mean the same thing" do
      for phrase <- ["ack", "heard", "seen", "on it", "engage"] do
        assert Phrases.parse(phrase) == :ack, "expected #{phrase} to acknowledge"
      end
    end

    test "case and trailing punctuation do not stop an acknowledgement" do
      assert Phrases.parse("Heard!") == :ack
      assert Phrases.parse("ON IT.") == :ack
      assert Phrases.parse("Seen") == :ack
      assert Phrases.parse("Resolved.") == :witness_close
    end

    test "an acknowledgement is still the whole message, not a word inside one" do
      assert Phrases.parse("seen that before, looking now") == :none
      assert Phrases.parse("I heard the build was red") == :none
      assert Phrases.parse("on it depends who you ask") == :none
    end
  end

  describe "note: (prefix + text + cause)" do
    test "a note with its cause on the next line carries both, verbatim" do
      assert Phrases.parse("note: flaky fixture; quarantined\ncause: shared test DB not reset") ==
               {:closure_note, "flaky fixture; quarantined", "shared test DB not reset"}
    end

    test "the cause marker is case-insensitive and tolerates leading space" do
      assert Phrases.parse("note: quarantined\n  Cause: DB state leaks") ==
               {:closure_note, "quarantined", "DB state leaks"}
    end

    test "one line works too — the cause runs to the end of the message" do
      assert Phrases.parse("note: quarantined cause: DB not reset") ==
               {:closure_note, "quarantined", "DB not reset"}
    end

    test "a note with no cause asks for one rather than logging half of it" do
      assert Phrases.parse("note: flaky fixture; quarantined") ==
               {:closure_note_needs_cause, "flaky fixture; quarantined"}
    end

    test "a cause marker with nothing after it is not a cause" do
      assert Phrases.parse("note: quarantined\ncause:") ==
               {:closure_note_needs_cause, "quarantined"}
    end

    test "an empty note is not a phrase" do
      assert Phrases.parse("note:") == :none
      assert Phrases.parse("note:   ") == :none
    end
  end

  describe "case-insensitive bare words + note: prefix (2026-07-24 field finding)" do
    test "bare-word phrases ignore case" do
      assert Phrases.parse("ACK") == :ack
      assert Phrases.parse("Ack") == :ack
      assert Phrases.parse("Resolved") == :witness_close
      assert Phrases.parse("WITHDRAW") == :withdraw
    end

    test "the note: prefix is case-insensitive but the note text stays verbatim" do
      assert Phrases.parse("Note: Flaky Fixture\ncause: Bad Data") ==
               {:closure_note, "Flaky Fixture", "Bad Data"}

      assert Phrases.parse("NOTE: quarantined") == {:closure_note_needs_cause, "quarantined"}
    end

    test "case-insensitivity does not extend to issue keys (still uppercase-only)" do
      assert Phrases.parse("eng-123") == :none
    end
  end

  describe "subject key (anchored, Linear grammar)" do
    test "a bare registered key is a subject" do
      assert Phrases.parse("ENG-123") == {:subject, "ENG-123"}
      assert Phrases.parse("  ENG-123  ") == {:subject, "ENG-123"}
    end

    test "a key embedded in a sentence is not a bare subject answer" do
      assert Phrases.parse("it is ENG-123 probably") == :none
    end

    test "non-key text is ordinary thread traffic" do
      assert Phrases.parse("looking into it") == :none
      assert Phrases.parse("eng-123") == :none
    end
  end

  describe "declining the question at release (ENG-60)" do
    test "the taught words are an answer, not a silence" do
      assert Phrases.parse("no note") == :closure_note_declined
      assert Phrases.parse("nothing to note") == :closure_note_declined
      assert Phrases.parse("skip") == :closure_note_declined
    end

    test "case and trailing punctuation do not change the answer" do
      assert Phrases.parse("No Note.") == :closure_note_declined
      assert Phrases.parse("SKIP!") == :closure_note_declined
    end

    test "the whole-message rule still guards it — these are common words" do
      assert Phrases.parse("no note needed, it was obvious") == :none
      assert Phrases.parse("I'll skip the standup") == :none
    end
  end

  describe "answer/1 (prose the bot asked for, no prefix)" do
    test "prose plus a cause line splits into the two halves, each trimmed" do
      assert Phrases.answer("the migration had not run\ncause: seed skips it") ==
               {:closure_note, "the migration had not run", "seed skips it"}
    end

    test "prose with no cause is not logged as half a note" do
      assert Phrases.answer("it was the migration again") ==
               {:closure_note_needs_cause, "it was the migration again"}
    end

    test "an empty answer is nothing at all" do
      assert Phrases.answer("   ") == :none
    end

    test "it splits exactly as the typed note: path does, so the two cannot drift" do
      typed = Phrases.parse("note: flaky fixture / cause: shared DB")
      asked = Phrases.answer("flaky fixture / cause: shared DB")

      assert typed == asked
    end
  end
end
