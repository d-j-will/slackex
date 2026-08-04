defmodule Slackex.Embeddings.OpenAIClientTest do
  use ExUnit.Case, async: false

  alias Slackex.Embeddings.OpenAIClient

  describe "generate_batch/1" do
    test "rejects batches exceeding 100 texts" do
      texts = for i <- 1..101, do: "text #{i}"
      assert {:error, :batch_too_large} = OpenAIClient.generate_batch(texts)
    end
  end

  defmodule EmbeddingPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => [%{"embedding" => [0.1, 0.2, 0.3], "index" => 0}],
          "usage" => %{"prompt_tokens" => 7, "total_tokens" => 7}
        })
      )
    end
  end

  describe "telemetry" do
    # This replaces a test that read openai_client.ex and grepped it for the
    # string ":telemetry.execute". That asserted the source spelling, not the
    # emission -- and it was the only thing standing where a real test should
    # be: test/slackex/ai/telemetry_test.exs calls :telemetry.execute itself
    # and asserts the handler's log, which is the "fakes the upstream" pattern
    # CLAUDE.md names as BAD after pipeline:events left listeners on a dead
    # topic for 18 hours. Between the two, nothing checked that the client
    # emits at all. This does, against a real HTTP round-trip, following the
    # Bandit-stub pattern in openai_compatible_client_streaming_test.exs.
    setup do
      original = Application.get_env(:slackex, :embedding_api)

      {:ok, server} = Bandit.start_link(plug: EmbeddingPlug, port: 0, ip: :loopback)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      Application.put_env(:slackex, :embedding_api, %{
        api_url: "http://localhost:#{port}/v1/embeddings",
        api_key: "test-key",
        model: "test-model",
        dimensions: 3
      })

      on_exit(fn ->
        Process.exit(server, :normal)
        Process.sleep(50)

        if original,
          do: Application.put_env(:slackex, :embedding_api, original),
          else: Application.delete_env(:slackex, :embedding_api)
      end)

      :ok
    end

    test "generating an embedding emits [:slackex, :ai, :embedding]" do
      handler_id = "embedding-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:slackex, :ai, :embedding],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, [_ | _]} = OpenAIClient.generate("some text to embed")

      assert_receive {:telemetry, [:slackex, :ai, :embedding], measurements, metadata}, 1_000

      assert is_integer(measurements.duration)
      assert metadata.model == "test-model"
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
