defmodule Slackex.Embeddings.OpenAIClientTest do
  use ExUnit.Case, async: true

  alias Slackex.Embeddings.OpenAIClient

  describe "generate_batch/1" do
    test "rejects batches exceeding 100 texts" do
      texts = for i <- 1..101, do: "text #{i}"
      assert {:error, :batch_too_large} = OpenAIClient.generate_batch(texts)
    end
  end

  describe "dimensions/0" do
    test "returns 1536 for text-embedding-3-small" do
      assert OpenAIClient.dimensions() == 1536
    end
  end
end
