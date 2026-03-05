defmodule Slackex.ApplicationTest do
  use ExUnit.Case, async: true

  alias Slackex.Application, as: App

  describe "maybe_embedding_serving/1" do
    setup do
      original = Application.get_env(:slackex, :embedding_client)
      on_exit(fn -> Application.put_env(:slackex, :embedding_client, original) end)
      :ok
    end

    test "includes Embeddings.Supervisor with temporary restart when client is BumblebeeClient" do
      Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.BumblebeeClient)

      assert [spec] = App.maybe_embedding_serving([])
      assert spec.id == Slackex.Embeddings.Supervisor
      assert spec.restart == :temporary
    end

    test "returns empty list when client is StubClient" do
      Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.StubClient)

      assert App.maybe_embedding_serving([]) == []
    end

    test "returns empty list when client is nil" do
      Application.delete_env(:slackex, :embedding_client)

      assert App.maybe_embedding_serving([]) == []
    end

    test "appends Embeddings.Supervisor to existing children" do
      Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.BumblebeeClient)

      existing = [:some_child, :another_child]
      result = App.maybe_embedding_serving(existing)

      assert length(result) == 3
      spec = List.last(result)
      assert spec.id == Slackex.Embeddings.Supervisor
      assert spec.restart == :temporary
    end
  end
end
