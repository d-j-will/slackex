defmodule Slackex.AI.LLMClientTest do
  use ExUnit.Case, async: true

  alias Slackex.AI.LLMClient

  describe "behaviour callbacks" do
    test "LLMClient defines complete/2 callback" do
      callbacks = LLMClient.behaviour_info(:callbacks)
      assert {:complete, 2} in callbacks
    end

    test "LLMClient defines stream/2 callback" do
      callbacks = LLMClient.behaviour_info(:callbacks)
      assert {:stream, 2} in callbacks
    end
  end

  describe "delegation" do
    test "complete/2 delegates to configured client" do
      messages = [%{role: "user", content: "Hello"}]
      result = LLMClient.complete(messages, [])
      assert {:ok, text} = result
      assert is_binary(text)
    end

    test "stream/2 delegates to configured client" do
      messages = [%{role: "user", content: "Hello"}]
      result = LLMClient.stream(messages, [])
      assert {:ok, stream} = result
      chunks = Enum.to_list(stream)
      assert [_ | _] = chunks
      assert Enum.all?(chunks, &is_binary/1)
    end
  end
end
