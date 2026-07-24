defmodule Slackex.Andon.AffordancesTest do
  @moduledoc """
  The in-thread lifecycle vocabulary (v1). Bare-word affordances act only as
  the whole trimmed message; `note:` is a prefix; a subject key is anchored.
  """
  use ExUnit.Case, async: true

  alias Slackex.Andon.Affordances

  describe "bare-word affordances (whole message only)" do
    test "ack acknowledges" do
      assert Affordances.parse("ack") == :ack
      assert Affordances.parse("  ack  ") == :ack
    end

    test "resolved is the witness close" do
      assert Affordances.parse("resolved") == :witness_close
    end

    test "withdraw drops the pull" do
      assert Affordances.parse("withdraw") == :withdraw
    end

    test "a bare word embedded in prose is not an affordance" do
      assert Affordances.parse("resolved, finally") == :none
      assert Affordances.parse("please ack this") == :none
      assert Affordances.parse("ack the thing") == :none
    end
  end

  describe "note: (prefix + text)" do
    test "captures the note text verbatim after the prefix" do
      assert Affordances.parse("note: flaky fixture; quarantined") ==
               {:closure_note, "flaky fixture; quarantined"}
    end

    test "an empty note is not an affordance" do
      assert Affordances.parse("note:") == :none
      assert Affordances.parse("note:   ") == :none
    end
  end

  describe "case-insensitive bare words + note: prefix (2026-07-24 field finding)" do
    test "bare-word affordances ignore case" do
      assert Affordances.parse("ACK") == :ack
      assert Affordances.parse("Ack") == :ack
      assert Affordances.parse("Resolved") == :witness_close
      assert Affordances.parse("WITHDRAW") == :withdraw
    end

    test "the note: prefix is case-insensitive but the note text stays verbatim" do
      assert Affordances.parse("Note: Flaky Fixture") == {:closure_note, "Flaky Fixture"}
      assert Affordances.parse("NOTE: quarantined") == {:closure_note, "quarantined"}
    end

    test "case-insensitivity does not extend to issue keys (still uppercase-only)" do
      assert Affordances.parse("eng-123") == :none
    end
  end

  describe "subject key (anchored, Linear grammar)" do
    test "a bare registered key is a subject" do
      assert Affordances.parse("ENG-123") == {:subject, "ENG-123"}
      assert Affordances.parse("  ENG-123  ") == {:subject, "ENG-123"}
    end

    test "a key embedded in a sentence is not a bare subject answer" do
      assert Affordances.parse("it is ENG-123 probably") == :none
    end

    test "non-key text is ordinary thread traffic" do
      assert Affordances.parse("looking into it") == :none
      assert Affordances.parse("eng-123") == :none
    end
  end
end
