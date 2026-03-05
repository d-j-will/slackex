defmodule Slackex.Embeddings.OpenAIClientTest do
  use ExUnit.Case, async: false

  alias Slackex.Embeddings.OpenAIClient

  describe "generate_batch/1" do
    test "rejects batches exceeding 100 texts" do
      texts = for i <- 1..101, do: "text #{i}"
      assert {:error, :batch_too_large} = OpenAIClient.generate_batch(texts)
    end
  end

  describe "telemetry" do
    test "source includes embedding telemetry emission" do
      source = File.read!("lib/slackex/embeddings/openai_client.ex")
      assert source =~ ":telemetry.execute"
      assert source =~ "[:slackex, :ai, :embedding]"
    end
  end

  describe "dimensions/0" do
    test "returns default 1536 when no embedding_api config" do
      prev = Application.get_env(:slackex, :embedding_api)
      Application.delete_env(:slackex, :embedding_api)

      on_exit(fn ->
        if prev, do: Application.put_env(:slackex, :embedding_api, prev)
      end)

      assert OpenAIClient.dimensions() == 1536
    end

    test "returns configured dimensions from embedding_api" do
      prev = Application.get_env(:slackex, :embedding_api)

      Application.put_env(:slackex, :embedding_api, %{
        dimensions: 384,
        api_url: "https://api.deepinfra.com/v1/openai/embeddings",
        model: "sentence-transformers/all-MiniLM-L6-v2",
        api_key: "test-key"
      })

      on_exit(fn ->
        if prev,
          do: Application.put_env(:slackex, :embedding_api, prev),
          else: Application.delete_env(:slackex, :embedding_api)
      end)

      assert OpenAIClient.dimensions() == 384
    end
  end
end
