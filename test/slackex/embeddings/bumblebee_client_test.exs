defmodule Slackex.Embeddings.BumblebeeClientTest do
  use ExUnit.Case, async: false

  alias Slackex.Embeddings.BumblebeeClient

  @dimensions 384

  describe "dimensions/0" do
    test "returns 384" do
      assert BumblebeeClient.dimensions() == @dimensions
    end
  end

  describe "generate/1 when serving is not running" do
    test "returns {:error, reason} with serving_not_running" do
      assert {:error, {:serving_not_running, _reason}} = BumblebeeClient.generate("hello")
    end
  end

  describe "generate_batch/1 when serving is not running" do
    test "returns {:error, reason} with serving_not_running" do
      assert {:error, {:serving_not_running, _reason}} =
               BumblebeeClient.generate_batch(["hello", "world"])
    end
  end

  describe "with fake serving" do
    setup do
      stop_serving()

      serving =
        Nx.Serving.new(fn _opts ->
          fn %Nx.Batch{} = batch ->
            Nx.broadcast(Nx.tensor(0.05), {batch.size, @dimensions})
          end
        end)
        |> Nx.Serving.client_preprocessing(fn input ->
          inputs = if is_list(input), do: input, else: [input]
          batch = Nx.Batch.stack(Enum.map(inputs, fn _text -> Nx.tensor([1.0]) end))
          {batch, %{count: length(inputs), is_list: is_list(input)}}
        end)
        |> Nx.Serving.client_postprocessing(fn {result, _metadata}, info ->
          if info.count == 1 and not info.is_list do
            %{embedding: result[0]}
          else
            Enum.map(0..(info.count - 1), fn i -> %{embedding: result[i]} end)
          end
        end)

      {:ok, pid} =
        Nx.Serving.start_link(
          serving: serving,
          name: Slackex.Embeddings.EmbeddingServing,
          batch_timeout: 50
        )

      Process.unlink(pid)

      on_exit(fn -> stop_serving() end)

      :ok
    end

    test "generate/1 returns {:ok, vector} with 384 floats" do
      assert {:ok, vector} = BumblebeeClient.generate("hello world")
      assert length(vector) == @dimensions
      assert Enum.all?(vector, &is_float/1)
    end

    test "generate_batch/1 returns {:ok, vectors} preserving input order and count" do
      texts = ["alpha", "beta", "gamma"]
      assert {:ok, vectors} = BumblebeeClient.generate_batch(texts)
      assert length(vectors) == 3
      assert Enum.all?(vectors, fn v -> length(v) == @dimensions end)
    end

    test "generate_batch/1 vectors contain floats" do
      assert {:ok, vectors} = BumblebeeClient.generate_batch(["one", "two"])
      assert Enum.all?(List.flatten(vectors), &is_float/1)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp stop_serving do
    case Process.whereis(Slackex.Embeddings.EmbeddingServing) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end
    end
  end
end
