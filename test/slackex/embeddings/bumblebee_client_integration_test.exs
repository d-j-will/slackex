defmodule Slackex.Embeddings.BumblebeeClientIntegrationTest do
  @moduledoc """
  Integration tests for BumblebeeClient with real model inference.

  These tests require downloading the sentence-transformers/all-MiniLM-L6-v2
  model and compiling with EXLA. They are excluded from the default test suite.

  Run with: mix test --include bumblebee
  """

  use ExUnit.Case, async: false

  @moduletag :bumblebee

  alias Slackex.Embeddings.BumblebeeClient

  setup_all do
    {:ok, _pid} = Slackex.Embeddings.EmbeddingServing.start_link([])
    :ok
  end

  describe "generate/1" do
    test "produces 384-dimensional vectors" do
      {:ok, vector} = BumblebeeClient.generate("hello world")

      assert length(vector) == 384
      assert Enum.all?(vector, &is_float/1)
    end

    test "vectors are L2-normalized with magnitude near 1.0" do
      {:ok, vector} = BumblebeeClient.generate("test input")

      magnitude =
        vector
        |> Enum.map(&(&1 * &1))
        |> Enum.sum()
        |> :math.sqrt()

      assert_in_delta magnitude, 1.0, 0.01
    end

    test "identical inputs produce identical output" do
      {:ok, first} = BumblebeeClient.generate("determinism test")
      {:ok, second} = BumblebeeClient.generate("determinism test")

      assert first == second
    end

    test "similar inputs have higher cosine similarity than dissimilar inputs" do
      {:ok, cat_sentence} = BumblebeeClient.generate("the cat sat on the mat")
      {:ok, kitten_sentence} = BumblebeeClient.generate("the kitten rested on the rug")
      {:ok, physics_sentence} = BumblebeeClient.generate("quantum physics equations")

      similar_score = cosine_similarity(cat_sentence, kitten_sentence)
      dissimilar_score = cosine_similarity(cat_sentence, physics_sentence)

      assert similar_score > dissimilar_score
    end
  end

  describe "generate_batch/1" do
    test "preserves input order and matches individual generation" do
      texts = ["alpha", "beta", "gamma"]
      {:ok, batch_vectors} = BumblebeeClient.generate_batch(texts)

      assert length(batch_vectors) == 3

      for {text, batch_vector} <- Enum.zip(texts, batch_vectors) do
        {:ok, single_vector} = BumblebeeClient.generate(text)
        assert batch_vector == single_vector
      end
    end
  end

  describe "dimensions/0" do
    test "returns 384" do
      assert BumblebeeClient.dimensions() == 384
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp cosine_similarity(vector_a, vector_b) do
    dot_product =
      Enum.zip(vector_a, vector_b)
      |> Enum.map(fn {x, y} -> x * y end)
      |> Enum.sum()

    magnitude_a =
      vector_a |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

    magnitude_b =
      vector_b |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

    dot_product / (magnitude_a * magnitude_b)
  end
end
