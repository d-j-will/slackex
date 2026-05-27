defmodule Slackex.Sous.DecisionTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous.Decision

  test "requires work_item_id and what; why/next optional" do
    cs = Decision.changeset(%Decision{}, %{work_item_id: 1, what: "Use ES"})
    assert cs.valid?

    cs2 = Decision.changeset(%Decision{}, %{work_item_id: 1})
    refute cs2.valid?
    assert errors_on(cs2)[:what]
  end
end
