defmodule Slackex.Sous.WorkItemFacetTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous.WorkItemFacet

  test "attentions/0 enumerates the four values" do
    assert WorkItemFacet.attentions() == [:act, :watch, :know, :hidden]
  end

  test "changeset requires work_item_id, viewer_id, attention" do
    cs = WorkItemFacet.changeset(%WorkItemFacet{}, %{})
    refute cs.valid?
    assert %{work_item_id: _, viewer_id: _, attention: _} = errors_on(cs)
  end

  test "changeset rejects an unknown attention" do
    cs =
      WorkItemFacet.changeset(%WorkItemFacet{}, %{
        work_item_id: 1,
        viewer_id: "cto",
        attention: :bogus
      })

    refute cs.valid?
    assert errors_on(cs)[:attention]
  end

  test "valid changeset sets updated_at automatically" do
    cs =
      WorkItemFacet.changeset(%WorkItemFacet{}, %{
        work_item_id: 1,
        viewer_id: "cto",
        attention: :act
      })

    assert cs.valid?
    assert get_change(cs, :updated_at)
  end
end
