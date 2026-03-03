defmodule Slackex.Embeddings.StubClient do
  @moduledoc """
  Deterministic embedding client for test and development environments.

  Generates reproducible embedding vectors by seeding `:rand` with the
  phash2 of the input text. The resulting vector is normalized to unit length.
  This guarantees that the same input always produces the same output without
  any network calls.
  """

  @behaviour Slackex.Embeddings.EmbeddingClient

  @dimensions 1536

  @impl true
  @spec generate(String.t()) :: {:ok, [float()]}
  def generate(text) do
    seed = :erlang.phash2(text)
    state = :rand.seed_s(:exsss, {seed, seed, seed})

    {raw_vector, _state} =
      Enum.map_reduce(1..@dimensions, state, fn _index, current_state ->
        :rand.uniform_s(current_state)
      end)

    {:ok, normalize(raw_vector)}
  end

  @impl true
  @spec generate_batch([String.t()]) :: {:ok, [[float()]]}
  def generate_batch(texts) do
    vectors =
      Enum.map(texts, fn text ->
        {:ok, vector} = generate(text)
        vector
      end)

    {:ok, vectors}
  end

  @impl true
  @spec dimensions() :: pos_integer()
  def dimensions, do: @dimensions

  defp normalize(vector) do
    magnitude =
      vector
      |> Enum.map(fn x -> x * x end)
      |> Enum.sum()
      |> :math.sqrt()

    Enum.map(vector, fn x -> x / magnitude end)
  end
end
