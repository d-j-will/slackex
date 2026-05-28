defmodule Slackex.Sous.ViewerTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous.Viewer

  test "default seed loaded by the B1 migration is queryable" do
    viewers = Repo.all(Viewer)
    ids = viewers |> Enum.map(& &1.id) |> MapSet.new()

    for id <- ~w(ceo cto em product csm arch staff) do
      assert MapSet.member?(ids, id), "expected seeded viewer #{id} to be present"
    end
  end

  test "changeset requires id, name, color" do
    cs = Viewer.changeset(%Viewer{}, %{})
    refute cs.valid?
    assert %{id: _, name: _, color: _} = errors_on(cs)
  end

  test "changeset accepts a full viewer" do
    cs =
      Viewer.changeset(%Viewer{}, %{
        id: "dev",
        name: "Developer",
        color: "#aabbcc",
        focus: ["foo"],
        position: 99
      })

    assert cs.valid?
  end
end
