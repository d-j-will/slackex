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

  test "changeset casts the B2 facet text fields" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    cs =
      WorkItemFacet.changeset(%WorkItemFacet{}, %{
        work_item_id: 1,
        viewer_id: "cto",
        attention: :act,
        facet_text: "the prism text",
        facet_model: "stub",
        facet_prompt_version: 1,
        facet_generated_at: now,
        facet_stale_at: nil
      })

    assert cs.valid?
    assert get_field(cs, :facet_text) == "the prism text"
    assert get_field(cs, :facet_model) == "stub"
    assert get_field(cs, :facet_prompt_version) == 1
    assert get_field(cs, :facet_generated_at) == now
  end

  describe "state/3 pill-state derivation" do
    test "viewer in enqueued_set -> :generating (wins over any row state)" do
      fresh_row = %WorkItemFacet{
        facet_text: "text",
        facet_prompt_version: 1,
        facet_stale_at: nil
      }

      assert WorkItemFacet.state(fresh_row, MapSet.new(["cto"]), "cto") == :generating
    end

    test "nil row -> :never_generated" do
      assert WorkItemFacet.state(nil, MapSet.new(), "cto") == :never_generated
    end

    test "row with nil facet_text -> :never_generated" do
      row = %WorkItemFacet{facet_text: nil, facet_prompt_version: nil}
      assert WorkItemFacet.state(row, MapSet.new(), "cto") == :never_generated
    end

    test "row with facet_text + facet_stale_at set -> :stale" do
      row = %WorkItemFacet{
        facet_text: "text",
        facet_prompt_version: 1,
        facet_stale_at: DateTime.utc_now()
      }

      assert WorkItemFacet.state(row, MapSet.new(), "cto") == :stale
    end

    test "row with prompt_version below current -> :stale" do
      row = %WorkItemFacet{
        facet_text: "text",
        facet_prompt_version: 0,
        facet_stale_at: nil
      }

      assert WorkItemFacet.state(row, MapSet.new(), "cto") == :stale
    end

    test "row with facet_text + current prompt_version + no stale_at -> :fresh" do
      row = %WorkItemFacet{
        facet_text: "text",
        facet_prompt_version: 1,
        facet_stale_at: nil
      }

      assert WorkItemFacet.state(row, MapSet.new(), "cto") == :fresh
    end
  end
end
