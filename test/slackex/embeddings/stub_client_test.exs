defmodule Slackex.Embeddings.StubClientTest do
  use ExUnit.Case, async: true

  alias Slackex.Embeddings.StubClient

  @dimensions 1536

  describe "generate/1" do
    test "returns {:ok, vector} with exactly 1536 dimensions" do
      assert {:ok, vector} = StubClient.generate("hello world")
      assert length(vector) == @dimensions
      assert Enum.all?(vector, &is_float/1)
    end

    test "returns identical vectors for the same input (deterministic)" do
      assert {:ok, vector_a} = StubClient.generate("deterministic input")
      assert {:ok, vector_b} = StubClient.generate("deterministic input")
      assert vector_a == vector_b
    end

    test "returns different vectors for different inputs" do
      assert {:ok, vector_a} = StubClient.generate("input one")
      assert {:ok, vector_b} = StubClient.generate("input two")
      refute vector_a == vector_b
    end

    test "produces unit-length vectors (normalized)" do
      assert {:ok, vector} = StubClient.generate("normalize me")

      magnitude =
        vector
        |> Enum.map(fn x -> x * x end)
        |> Enum.sum()
        |> :math.sqrt()

      assert_in_delta magnitude, 1.0, 1.0e-6
    end
  end

  describe "generate_batch/1" do
    test "returns {:ok, vectors} where each vector has 1536 dimensions" do
      texts = ["alpha", "beta", "gamma"]
      assert {:ok, vectors} = StubClient.generate_batch(texts)
      assert length(vectors) == 3
      assert Enum.all?(vectors, fn v -> length(v) == @dimensions end)
    end

    test "batch results match individual generate/1 calls" do
      texts = ["foo", "bar", "baz"]
      assert {:ok, batch_vectors} = StubClient.generate_batch(texts)

      individual_vectors =
        Enum.map(texts, fn text ->
          {:ok, vector} = StubClient.generate(text)
          vector
        end)

      assert batch_vectors == individual_vectors
    end

    test "handles up to 100 texts" do
      texts = for i <- 1..100, do: "text #{i}"
      assert {:ok, vectors} = StubClient.generate_batch(texts)
      assert length(vectors) == 100
    end
  end

  describe "dimensions/0" do
    test "returns 1536" do
      assert StubClient.dimensions() == @dimensions
    end
  end
end
