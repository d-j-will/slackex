defmodule Slackex.Andon.HelpTest do
  @moduledoc """
  The discovery phrase, and — more importantly — everything it must refuse.

  `help` is the word people reach for when they are stuck (ENG-45 collected
  the register: "I need help", "I'm a bit stuck here, someone help"). Answering
  that with a syntax list would hand a manual to someone asking for a person,
  so the negative cases here are the point of the module, not its edge.
  """
  use ExUnit.Case, async: true

  alias Slackex.Andon.Help

  describe "the phrase that asks" do
    test "the exact phrase asks for help" do
      assert Help.asked?("andon help")
    end

    test "case does not matter" do
      assert Help.asked?("Andon Help")
      assert Help.asked?("ANDON HELP")
    end

    test "surrounding whitespace does not matter" do
      assert Help.asked?("  andon help\n")
    end

    test "the punctuation someone actually types does not matter" do
      assert Help.asked?("andon help?")
      assert Help.asked?("andon help.")
      assert Help.asked?("andon help!")
    end
  end

  describe "what must never be mistaken for it" do
    test "a bare cry for help is not a request for the syntax" do
      refute Help.asked?("help")
      refute Help.asked?("I need help")
      refute Help.asked?("I'm a bit stuck here, someone help")
      refute Help.asked?("help!")
    end

    test "the phrase must be the whole message, not buried in one" do
      refute Help.asked?("does andon help with this?")
      refute Help.asked?("andon help would be nice to have")
    end

    test "a longer word starting with it is not it" do
      refute Help.asked?("andon helpful")
    end

    test "ordinary traffic is ordinary traffic" do
      refute Help.asked?("")
      refute Help.asked?("pull: defect the build is red on main")
      refute Help.asked?("resolved")
    end
  end
end
