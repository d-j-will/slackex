defmodule Slackex.Embeddings.OpenAIClient do
  @moduledoc """
  OpenAI-compatible embedding client.

  Sends requests to any OpenAI-compatible embeddings API (OpenAI, DeepInfra,
  OpenRouter, HuggingFace Inference, etc.) via Req. Enforces a maximum batch
  size of 100 texts per API call. Response vectors are sorted by the `index`
  field to preserve input ordering.

  ## Configuration

      config :slackex, :embedding_api,
        api_url: "https://api.deepinfra.com/v1/openai/embeddings",
        model: "sentence-transformers/all-MiniLM-L6-v2",
        dimensions: 384,
        api_key: "your-api-key"

  Falls back to legacy config (`openai_api_key`, OpenAI defaults) when
  `:embedding_api` is not set.
  """

  @behaviour Slackex.Embeddings.EmbeddingClient

  @default_api_url "https://api.openai.com/v1/embeddings"
  @default_model "text-embedding-3-small"
  @default_dimensions 1536
  @max_batch_size 100
  @receive_timeout_ms 30_000

  @impl true
  @spec generate(String.t()) :: {:ok, [float()]} | {:error, term()}
  def generate(text) do
    case generate_batch([text]) do
      {:ok, [vector]} -> {:ok, vector}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec generate_batch([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def generate_batch(texts) when length(texts) > @max_batch_size do
    {:error, :batch_too_large}
  end

  def generate_batch(texts) do
    start_time = System.monotonic_time()

    body = %{
      model: config(:model, @default_model),
      input: texts
    }

    case Req.post(config(:api_url, @default_api_url),
           json: body,
           headers: [
             {"authorization", "Bearer #{api_key()}"},
             {"content-type", "application/json"}
           ],
           receive_timeout: @receive_timeout_ms
         ) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        vectors =
          response_body
          |> Map.get("data", [])
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        emit_telemetry(start_time, response_body, length(texts))
        {:ok, vectors}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, exception} ->
        {:error, {:network_error, exception}}
    end
  end

  @impl true
  @spec dimensions() :: pos_integer()
  def dimensions, do: config(:dimensions, @default_dimensions)

  defp config(key, default) do
    case Application.get_env(:slackex, :embedding_api) do
      nil -> default
      config when is_map(config) -> Map.get(config, key, default)
      config when is_list(config) -> Keyword.get(config, key, default)
    end
  end

  defp emit_telemetry(start_time, response_body, batch_size) do
    duration = System.monotonic_time() - start_time
    usage = Map.get(response_body, "usage", %{})

    :telemetry.execute(
      [:slackex, :ai, :embedding],
      %{duration: duration},
      %{
        model: config(:model, @default_model),
        tokens: Map.get(usage, "total_tokens", 0),
        batch_size: batch_size
      }
    )
  end

  defp api_key do
    case Application.get_env(:slackex, :embedding_api) do
      nil -> Application.get_env(:slackex, :openai_api_key)
      config when is_map(config) -> Map.get(config, :api_key)
      config when is_list(config) -> Keyword.get(config, :api_key)
    end
  end
end
