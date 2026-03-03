defmodule Slackex.Embeddings.EmbeddingClient do
  @moduledoc """
  Behaviour and delegation module for embedding generation.

  Defines the contract for embedding clients and delegates calls
  to the configured implementation via Application config.

  ## Configuration

      config :slackex, :embedding_client, Slackex.Embeddings.StubClient

  ## Callbacks

  Implementations must provide:
  - `generate/1` -- embed a single text string
  - `generate_batch/1` -- embed a list of text strings
  - `dimensions/0` -- the dimensionality of produced vectors
  """

  @callback generate(text :: String.t()) :: {:ok, [float()]} | {:error, term()}
  @callback generate_batch(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  @callback dimensions() :: pos_integer()

  @doc "Generates an embedding vector for a single text string."
  @spec generate(String.t()) :: {:ok, [float()]} | {:error, term()}
  def generate(text) do
    client().generate(text)
  end

  @doc "Generates embedding vectors for a list of text strings."
  @spec generate_batch([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def generate_batch(texts) do
    client().generate_batch(texts)
  end

  @doc "Returns the dimensionality of vectors produced by the configured client."
  @spec dimensions() :: pos_integer()
  def dimensions do
    client().dimensions()
  end

  defp client do
    Application.get_env(:slackex, :embedding_client)
  end
end
