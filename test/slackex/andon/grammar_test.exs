defmodule Slackex.Andon.GrammarTest do
  @moduledoc """
  The conformance claim for slackex (relay #1): every `grammar_cases` entry in
  the vendored relay-conformance fixture must map to the expected outcome
  through `Slackex.Andon.Grammar.parse/1`.

  The fixture at `test/support/andon_conformance/grammar.json` is a
  byte-identical copy of `priv/relay_conformance/v1/grammar.json` from the
  andon service repo (github.com/davewil/andon). Source commit + sha256 are
  recorded in `test/support/andon_conformance/PROVENANCE.md`. Loading the file
  itself — rather than restating the cases — is what makes the passing run a
  conformance claim: the two halves of the contract cannot drift unnoticed.

  Scope: v1 exercises the **text grammar half** of C1. The fixture's
  `identical_event_rule` (the optional `/pull` slash-command adapter must
  produce byte-equal domain events) is deferred pending a `/pull` adapter; see
  the PROVENANCE note. This test asserts that deferral is explicit, not silent.
  """
  use ExUnit.Case, async: true

  alias Slackex.Andon.Grammar

  @fixture_path Path.join([__DIR__, "..", "..", "support", "andon_conformance", "grammar.json"])
  @external_resource @fixture_path

  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  test "the fixture is the version-1 relay-conformance grammar contract" do
    assert @fixture["contract"] == "relay-conformance"
    assert @fixture["version"] == 1
    assert @fixture["grammar_cases"] != []
  end

  describe "grammar_cases (the executable C1 conformance suite)" do
    for grammar_case <- @fixture["grammar_cases"] do
      @case grammar_case
      test "#{grammar_case["name"]}" do
        %{"input" => input, "expect" => expect} = @case

        assert input["kind"] == "message",
               "v1 conformance covers text-message inputs; adapter inputs are deferred"

        outcome = Grammar.parse(input["text"])

        case expect["outcome"] do
          "pull_created" ->
            assert {:pull, class, sentence} = outcome
            assert class == expect["class"]
            assert sentence == expect["sentence"]

          "correction" ->
            assert outcome == :correction

          "not_a_pull" ->
            assert outcome == :not_a_pull
        end
      end
    end
  end

  test "every class the fixture claims is a recognised class" do
    claimed =
      for c <- @fixture["grammar_cases"],
          c["expect"]["outcome"] == "pull_created",
          uniq: true,
          do: c["expect"]["class"]

    assert claimed != []
    assert Enum.all?(claimed, &(&1 in Grammar.classes()))
  end

  test "identical_event_rule is present but its /pull adapter is deferred in v1" do
    # The fixture carries the rule; v1 ships text-grammar only, so there is no
    # second input method to compare. This test documents the deferral so it
    # cannot be lost — a finding, not a silent skip (project CLAUDE.md).
    assert @fixture["identical_event_rule"]["equality"]["scope"] == "full_domain_event"
  end
end
