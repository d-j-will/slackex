defmodule Slackex.Links.LinkPreviewListenerTest do
  use Slackex.DataCase, async: false

  alias Slackex.Links.{LinkPreview, LinkPreviewListener}

  describe "handle_info/2 with :messages_persisted" do
    setup do
      {:ok, pid} = LinkPreviewListener.start_link(name: nil)
      %{pid: pid}
    end

    test "processes messages containing URLs", %{pid: pid} do
      message = insert(:message, content: "Check https://pornhub.com")

      # Send the event and wait for GenServer to process it
      send(pid, {:messages_persisted, [message.id]})
      _ = :sys.get_state(pid)

      # The worker runs inline in test mode, so a blocked preview should exist
      preview = Repo.get_by(LinkPreview, message_id: message.id)
      assert preview != nil
      assert preview.status == "blocked"
      assert preview.blocked_reason == "blocklist"
    end

    test "ignores messages without URLs", %{pid: pid} do
      message = insert(:message, content: "Hello world!")

      send(pid, {:messages_persisted, [message.id]})
      _ = :sys.get_state(pid)

      assert Repo.get_by(LinkPreview, message_id: message.id) == nil
    end
  end
end
