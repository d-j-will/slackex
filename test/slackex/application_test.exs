defmodule Slackex.ApplicationTest do
  use ExUnit.Case, async: true

  alias Slackex.Application, as: App

  describe "maybe_embedding_serving/1" do
    setup do
      original = Application.get_env(:slackex, :embedding_client)
      on_exit(fn -> Application.put_env(:slackex, :embedding_client, original) end)
      :ok
    end

    test "includes EmbeddingServing when client is BumblebeeClient" do
      Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.BumblebeeClient)

      assert App.maybe_embedding_serving([]) == [Slackex.Embeddings.Supervisor]
    end

    test "returns empty list when client is StubClient" do
      Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.StubClient)

      assert App.maybe_embedding_serving([]) == []
    end

    test "returns empty list when client is nil" do
      Application.delete_env(:slackex, :embedding_client)

      assert App.maybe_embedding_serving([]) == []
    end

    test "appends EmbeddingServing to existing children" do
      Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.BumblebeeClient)

      existing = [:some_child, :another_child]

      assert App.maybe_embedding_serving(existing) ==
               [:some_child, :another_child, Slackex.Embeddings.Supervisor]
    end
  end
end
