defmodule Slackex.Embeddings.EmbeddingClientTest do
  use ExUnit.Case, async: true

  alias Slackex.Embeddings.EmbeddingClient

  describe "config resolution" do
    test "test environment is configured to use StubClient" do
      client = Application.get_env(:slackex, :embedding_client)
      assert client == Slackex.Embeddings.StubClient
    end
  end

  describe "delegation" do
    test "generate/1 delegates to configured client" do
      assert {:ok, vector} = EmbeddingClient.generate("test delegation")
      assert length(vector) == 384
      assert is_list(vector)
    end

    test "generate_batch/1 delegates to configured client" do
      assert {:ok, vectors} = EmbeddingClient.generate_batch(["a", "b"])
      assert length(vectors) == 2
    end

    test "dimensions/0 delegates to configured client" do
      assert EmbeddingClient.dimensions() == 384
    end
  end
end
