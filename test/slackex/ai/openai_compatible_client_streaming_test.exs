defmodule Slackex.AI.OpenAICompatibleClientStreamingTest do
  @moduledoc """
  Integration test for OpenAI-compatible streaming via Req's `into: :self`.

  Spins up a real Bandit HTTP server that emits SSE (Server-Sent Events)
  in the OpenAI chat completions format, then verifies the full streaming
  pipeline produces actual content chunks.

  This test exists because unit tests with mocked HTTP don't exercise the
  Req async message protocol (Mint messages -> Req.parse_message/2).
  See: docs/rca/2026-03-06-summarization-streaming-failure.md
  """
  use ExUnit.Case, async: false

  alias Slackex.AI.OpenAICompatibleClient

  defmodule SSEPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.request_path do
        "/chat/completions" ->
          sse_response(conn)

        "/error/chat/completions" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(500, Jason.encode!(%{"error" => "internal server error"}))

        "/empty/chat/completions" ->
          sse_empty_response(conn)

        _ ->
          send_resp(conn, 404, "not found")
      end
    end

    defp sse_response(conn) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      chunks = [
        sse_chunk("Hello"),
        sse_chunk(", "),
        sse_chunk("world"),
        sse_chunk("!"),
        "data: [DONE]\n\n"
      ]

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end

    defp sse_empty_response(conn) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
      conn
    end

    defp sse_chunk(content) do
      data =
        Jason.encode!(%{
          "choices" => [%{"delta" => %{"content" => content}, "index" => 0}]
        })

      "data: #{data}\n\n"
    end
  end

  setup do
    original = Application.get_env(:slackex, :llm_api)

    {:ok, server} = Bandit.start_link(plug: SSEPlug, port: 0, ip: :loopback)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      Process.exit(server, :normal)
      Process.sleep(50)

      if original,
        do: Application.put_env(:slackex, :llm_api, original),
        else: Application.delete_env(:slackex, :llm_api)
    end)

    %{port: port}
  end

  defp configure_client(port, path_prefix \\ "") do
    Application.put_env(:slackex, :llm_api, %{
      api_url: "http://127.0.0.1:#{port}#{path_prefix}",
      model: "test-model",
      api_key: "test-key",
      max_tokens: 64,
      temperature: 0.0
    })
  end

  describe "stream/2 integration" do
    test "streams SSE chunks from a real HTTP server", %{port: port} do
      configure_client(port)

      {:ok, stream} =
        OpenAICompatibleClient.stream(
          [%{role: "user", content: "say hello"}],
          []
        )

      chunks = Enum.to_list(stream)
      joined = Enum.join(chunks)

      assert joined == "Hello, world!"
      assert chunks != []
    end

    test "handles API error responses", %{port: port} do
      configure_client(port, "/error")

      result =
        OpenAICompatibleClient.stream(
          [%{role: "user", content: "test"}],
          []
        )

      # stream/2 returns {:ok, stream} even for errors because the error
      # happens during enumeration, OR it may fail at start_stream
      case result do
        {:ok, stream} ->
          chunks = Enum.to_list(stream)
          assert chunks == []

        {:error, {:api_error, 500, _}} ->
          :ok
      end
    end

    test "handles stream with no content (only [DONE])", %{port: port} do
      configure_client(port, "/empty")

      {:ok, stream} =
        OpenAICompatibleClient.stream(
          [%{role: "user", content: "test"}],
          []
        )

      chunks = Enum.to_list(stream)
      assert chunks == []
    end
  end
end
