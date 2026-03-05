defmodule Slackex.AI.OpenAICompatibleClient do
  @moduledoc """
  OpenAI-compatible chat completions client.

  Sends requests to any OpenAI-compatible chat completions API
  (DeepInfra, OpenRouter, OpenAI, etc.) via Req.

  ## Configuration

      config :slackex, :llm_api, %{
        api_url: "https://api.deepinfra.com/v1/openai",
        model: "google/gemma-3-4b-it",
        api_key: "your-key",
        max_tokens: 1024,
        temperature: 0.3
      }
  """

  @behaviour Slackex.AI.LLMClient

  @default_api_url "https://api.deepinfra.com/v1/openai"
  @default_model "google/gemma-3-4b-it"
  @default_max_tokens 1024
  @default_temperature 0.3
  @receive_timeout_ms 60_000

  @impl true
  def complete(messages, opts \\ []) do
    with {:ok, api_key} <- fetch_api_key() do
      body = build_body(messages, opts, false)
      start_time = System.monotonic_time()

      case Req.post(completions_url(),
             json: body,
             headers: auth_headers(api_key),
             receive_timeout: @receive_timeout_ms
           ) do
        {:ok, %Req.Response{status: 200, body: response_body}} ->
          content =
            response_body
            |> get_in(["choices", Access.at(0), "message", "content"])

          emit_telemetry(start_time, response_body)
          {:ok, content || ""}

        {:ok, %Req.Response{status: status, body: response_body}} ->
          {:error, {:api_error, status, response_body}}

        {:error, exception} ->
          {:error, {:network_error, exception}}
      end
    end
  end

  @impl true
  def stream(messages, opts \\ []) do
    with {:ok, api_key} <- fetch_api_key() do
      body = build_body(messages, opts, true)
      start_time = System.monotonic_time()

      stream =
        Stream.resource(
          fn -> start_stream(body, api_key) end,
          &next_chunk/1,
          fn
            {:done, _ref} -> :ok
            {:error, _} -> :ok
            ref when is_reference(ref) -> :ok
          end
        )
        |> Stream.transform(
          fn -> nil end,
          fn chunk, _acc -> {[chunk], nil} end,
          fn _acc ->
            duration = System.monotonic_time() - start_time

            :telemetry.execute(
              [:slackex, :ai, :completion],
              %{duration: duration},
              %{
                model: config(:model, @default_model),
                prompt_tokens: 0,
                completion_tokens: 0,
                streaming: true
              }
            )
          end
        )

      {:ok, stream}
    end
  end

  # -- Streaming internals --

  defp start_stream(body, api_key) do
    case Req.post(completions_url(),
           json: body,
           headers: auth_headers(api_key),
           receive_timeout: @receive_timeout_ms,
           into: :self
         ) do
      {:ok, %Req.Response{status: 200} = resp} ->
        resp.body

      {:ok, %Req.Response{status: status}} ->
        {:error, {:api_error, status}}

      {:error, exception} ->
        {:error, {:network_error, exception}}
    end
  end

  defp next_chunk({:error, _reason} = err), do: {:halt, err}

  defp next_chunk(ref) when is_reference(ref) do
    receive do
      {^ref, {:data, data}} ->
        chunks = parse_sse_data(data)

        if :done in chunks do
          {Enum.filter(chunks, &is_binary/1), {:done, ref}}
        else
          {chunks, ref}
        end

      {^ref, :done} ->
        {:halt, {:done, ref}}
    after
      @receive_timeout_ms ->
        {:halt, {:error, :timeout}}
    end
  end

  defp next_chunk({:done, _ref} = done), do: {:halt, done}

  defp parse_sse_data(data) do
    data
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&parse_sse_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_sse_line(line) do
    json_str = String.trim_leading(line, "data: ")

    if json_str == "[DONE]" do
      :done
    else
      case Jason.decode(json_str) do
        {:ok, parsed} ->
          get_in(parsed, ["choices", Access.at(0), "delta", "content"]) || ""

        _ ->
          ""
      end
    end
  end

  # -- Request building --

  defp build_body(messages, opts, stream?) do
    %{
      model: Keyword.get(opts, :model, config(:model, @default_model)),
      messages: messages,
      max_tokens: Keyword.get(opts, :max_tokens, config(:max_tokens, @default_max_tokens)),
      temperature: config(:temperature, @default_temperature),
      stream: stream?
    }
  end

  defp completions_url do
    base = config(:api_url, @default_api_url)
    String.trim_trailing(base, "/") <> "/chat/completions"
  end

  defp auth_headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]
  end

  # -- Config helpers --

  defp fetch_api_key do
    case config(:api_key, nil) do
      nil -> {:error, :not_configured}
      key -> {:ok, key}
    end
  end

  defp config(key, default) do
    case Application.get_env(:slackex, :llm_api) do
      nil -> default
      config when is_map(config) -> Map.get(config, key, default)
      config when is_list(config) -> Keyword.get(config, key, default)
    end
  end

  defp emit_telemetry(start_time, response_body) do
    duration = System.monotonic_time() - start_time
    usage = Map.get(response_body, "usage", %{})

    :telemetry.execute(
      [:slackex, :ai, :completion],
      %{duration: duration},
      %{
        model: config(:model, @default_model),
        prompt_tokens: Map.get(usage, "prompt_tokens", 0),
        completion_tokens: Map.get(usage, "completion_tokens", 0)
      }
    )
  end
end
