defmodule Slackex.Embeddings.BumblebeeClient do
  @moduledoc """
  Embedding client backed by a local Bumblebee model via EmbeddingServing.

  Delegates `generate/1` and `generate_batch/1` to the EmbeddingServing
  process which runs `Nx.Serving.batched_run/2` against a loaded
  sentence-transformer model. Returns 384-dimensional vectors.

  When the EmbeddingServing process is unavailable, calls return one of:

    - `{:error, {:serving_not_running, reason}}` — process not started or crashed
    - `{:error, {:serving_error, message}}` — process raised during inference
  """

  @behaviour Slackex.Embeddings.EmbeddingClient

  alias Slackex.Embeddings.EmbeddingServing

  @dimensions 384

  @impl true
  @spec generate(String.t()) :: {:ok, [float()]} | {:error, term()}
  def generate(text) do
    case safe_run(text) do
      {:ok, %{embedding: tensor}} -> {:ok, Nx.to_flat_list(tensor)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec generate_batch([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def generate_batch(texts) do
    case safe_run(texts) do
      {:ok, results} when is_list(results) ->
        vectors = Enum.map(results, fn %{embedding: tensor} -> Nx.to_flat_list(tensor) end)
        {:ok, vectors}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec dimensions() :: pos_integer()
  def dimensions, do: @dimensions

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp safe_run(input) do
    {:ok, EmbeddingServing.run(input)}
  rescue
    e -> {:error, {:serving_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:serving_not_running, reason}}
  end
end
