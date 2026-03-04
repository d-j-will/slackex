defmodule Slackex.Embeddings.FailingClient do
  @moduledoc false

  @behaviour Slackex.Embeddings.EmbeddingClient

  @impl true
  def generate(_text), do: {:error, :api_error}

  @impl true
  def generate_batch(_texts), do: {:error, :api_error}

  @impl true
  def dimensions, do: 384
end
