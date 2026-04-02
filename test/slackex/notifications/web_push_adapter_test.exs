defmodule Slackex.Notifications.WebPushAdapterTest do
  use Slackex.DataCase, async: true

  alias Slackex.Notifications.WebPushAdapter

  describe "build_payload/1" do
    test "builds correct JSON from payload map" do
      payload = %{
        "title" => "#general",
        "body" => "alice: hello world",
        "tag" => "channel:123",
        "url" => "/chat/general",
        "type" => "new_message"
      }

      json = WebPushAdapter.build_payload(payload)
      decoded = Jason.decode!(json)

      assert decoded["title"] == "#general"
      assert decoded["body"] == "alice: hello world"
      assert decoded["tag"] == "channel:123"
      assert decoded["url"] == "/chat/general"
      assert decoded["type"] == "new_message"
    end

    test "handles nil values gracefully" do
      payload = %{
        "title" => "Test",
        "body" => "msg",
        "tag" => nil,
        "url" => nil,
        "type" => nil
      }

      json = WebPushAdapter.build_payload(payload)
      decoded = Jason.decode!(json)
      assert decoded["title"] == "Test"
      assert is_nil(decoded["tag"])
    end
  end
end
