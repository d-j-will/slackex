defmodule Slackex.BoundaryContractTest do
  @moduledoc """
  Liveness contract for compile-time boundary enforcement.

  Boundary was inert from its introduction (914f1f7) until the slackex-n3c
  retrofit because `:boundary` was listed AFTER `Mix.compilers()` — the tracer
  never attached during elixir compilation, so zero violations were ever
  reported and the gate looked green for the project's entire life. These
  tests pin the two facts that keep it alive: the compiler order, and full
  module classification. If either fails, enforcement is off again.
  """

  use ExUnit.Case, async: true

  @moduletag :contract

  test ":boundary compiler precedes the elixir compiler (tracer must attach first)" do
    compilers = Mix.Project.config()[:compilers]
    boundary_idx = Enum.find_index(compilers, &(&1 == :boundary))
    elixir_idx = Enum.find_index(compilers, &(&1 == :elixir))

    assert is_integer(boundary_idx), ":boundary missing from compilers — enforcement is off"

    assert elixir_idx == nil or boundary_idx < elixir_idx,
           ":boundary listed after the elixir compiler traces nothing and " <>
             "silently enforces nothing (slackex-n3c)"
  end

  test "the retrofitted boundaries carry a persisted Boundary declaration" do
    # `use Boundary` persists a `Boundary` module attribute into the beam —
    # readable via __info__(:attributes) without boundary's private internals.
    # Completeness (no unclassified module anywhere) is enforced by the
    # compiler itself: it warns on unclassified modules and CI compiles with
    # --warnings-as-errors, provided test 1 above holds.
    for ctx <- [
          Slackex.Sous,
          Slackex.Factory,
          Slackex.Analytics,
          Slackex.Markdown,
          Slackex.Ops.SystemSummary,
          Slackex.MixTasks,
          Slackex.Chat,
          Slackex.Accounts,
          SlackexWeb
        ] do
      assert Code.ensure_loaded?(ctx)

      assert Keyword.has_key?(ctx.__info__(:attributes), Boundary),
             "expected #{inspect(ctx)} to declare `use Boundary`"
    end
  end
end
