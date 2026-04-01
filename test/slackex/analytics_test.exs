defmodule Slackex.AnalyticsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Analytics.Event

  describe "Event.changeset/2" do
    test "valid attrs produce a valid changeset" do
      attrs = %{
        event_type: "page_view",
        event_category: "product",
        event_name: "chat_index_viewed",
        session_id: "test-session-123",
        metadata: %{"path" => "/chat/general"}
      }

      changeset = Event.changeset(%Event{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :id) != nil
      assert get_change(changeset, :inserted_at) != nil
    end

    test "rejects invalid event_type" do
      attrs = %{event_type: "invalid", event_category: "product", event_name: "test"}
      changeset = Event.changeset(%Event{}, attrs)
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:event_type]
    end

    test "rejects invalid event_category" do
      attrs = %{event_type: "page_view", event_category: "invalid", event_name: "test"}
      changeset = Event.changeset(%Event{}, attrs)
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:event_category]
    end

    test "requires event_type, event_category, event_name" do
      changeset = Event.changeset(%Event{}, %{})
      refute changeset.valid?
      assert changeset.errors[:event_type]
      assert changeset.errors[:event_category]
      assert changeset.errors[:event_name]
    end
  end
end
