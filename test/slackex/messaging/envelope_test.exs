defmodule Slackex.Messaging.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Slackex.Messaging.Envelope

  describe "wrap/4" do
    test "produces correct structure with v: 1" do
      envelope = Envelope.wrap("message.new", {:channel, 42}, %{content: "hello"})

      assert envelope.v == 1
      assert envelope.event == "message.new"
      assert is_map(envelope.target)
      assert is_map(envelope.payload)
      assert is_map(envelope.meta)
    end

    test "converts :channel target tuple to map" do
      envelope = Envelope.wrap("message.new", {:channel, 99}, %{})

      assert envelope.target == %{type: :channel, id: 99}
    end

    test "converts :dm target tuple to map" do
      envelope = Envelope.wrap("typing", {:dm, 7}, %{})

      assert envelope.target == %{type: :dm, id: 7}
    end

    test "includes sent_at DateTime in meta" do
      before = DateTime.utc_now()
      envelope = Envelope.wrap("typing", {:channel, 1}, %{})
      after_wrap = DateTime.utc_now()

      assert %DateTime{} = envelope.meta.sent_at
      assert DateTime.compare(envelope.meta.sent_at, before) in [:gt, :eq]
      assert DateTime.compare(envelope.meta.sent_at, after_wrap) in [:lt, :eq]
    end

    test "meta correlation_id is nil by default" do
      envelope = Envelope.wrap("message.new", {:channel, 1}, %{})

      assert is_nil(envelope.meta.correlation_id)
    end

    test "accepts optional correlation_id" do
      envelope = Envelope.wrap("message.new", {:channel, 1}, %{}, correlation_id: "abc-123")

      assert envelope.meta.correlation_id == "abc-123"
    end
  end

  describe "unwrap/1" do
    test "extracts event, target, and payload" do
      payload = %{content: "hello"}
      envelope = Envelope.wrap("message.new", {:channel, 5}, payload)

      {event, target, unwrapped_payload} = Envelope.unwrap(envelope)

      assert event == "message.new"
      assert target == %{type: :channel, id: 5}
      assert unwrapped_payload == payload
    end
  end
end
