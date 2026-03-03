defmodule Slackex.Embeddings.OpenAIClient do
  @moduledoc """
  OpenAI embedding client using the text-embedding-3-small model.

  Sends requests to the OpenAI embeddings API via Req. Enforces a maximum
  batch size of 100 texts per API call. Response vectors are sorted by the
  `index` field to preserve input ordering.

  ## Configuration

      config :slackex, :openai_api_key, "sk-..."
  """

  @behaviour Slackex.Embeddings.EmbeddingClient

  @dimensions 1536
  @model "text-embedding-3-small"
  @max_batch_size 100
  @api_url "https://api.openai.com/v1/embeddings"

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
    api_key = Application.get_env(:slackex, :openai_api_key)

    body = %{
      model: @model,
      input: texts
    }

    case Req.post(@api_url,
           json: body,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        vectors =
          response_body
          |> Map.get("data", [])
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, vectors}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, exception} ->
        {:error, {:network_error, exception}}
    end
  end

  @impl true
  @spec dimensions() :: pos_integer()
  def dimensions, do: @dimensions
end
