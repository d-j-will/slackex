defmodule Slackex.ApplicationTest do
  use ExUnit.Case, async: true

  alias Slackex.Application, as: App

  describe "maybe_embedding_serving/1" do
    test "includes EmbeddingServing when client is BumblebeeClient" do
      original = Application.get_env(:slackex, :embedding_client)

      try do
        Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.BumblebeeClient)

        children = App.maybe_embedding_serving([])

        assert children == [Slackex.Embeddings.EmbeddingServing]
      after
        Application.put_env(:slackex, :embedding_client, original)
      end
    end

    test "returns empty list when client is StubClient" do
      original = Application.get_env(:slackex, :embedding_client)

      try do
        Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.StubClient)

        children = App.maybe_embedding_serving([])

        assert children == []
      after
        Application.put_env(:slackex, :embedding_client, original)
      end
    end

    test "returns empty list when client is nil" do
      original = Application.get_env(:slackex, :embedding_client)

      try do
        Application.delete_env(:slackex, :embedding_client)

        children = App.maybe_embedding_serving([])

        assert children == []
      after
        Application.put_env(:slackex, :embedding_client, original)
      end
    end

    test "appends EmbeddingServing to existing children" do
      original = Application.get_env(:slackex, :embedding_client)

      try do
        Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.BumblebeeClient)

        existing = [:some_child, :another_child]
        children = App.maybe_embedding_serving(existing)

        assert children == [:some_child, :another_child, Slackex.Embeddings.EmbeddingServing]
      after
        Application.put_env(:slackex, :embedding_client, original)
      end
    end
  end
end
