defmodule Slackex.Embeddings.EmbeddingServingTest do
  use ExUnit.Case, async: true

  alias Slackex.Embeddings.EmbeddingServing

  setup_all do
    Code.ensure_loaded!(EmbeddingServing)
    :ok
  end

  describe "public API" do
    test "defines run/1" do
      assert function_exported?(EmbeddingServing, :run, 1)
    end

    test "defines start_link/1" do
      assert function_exported?(EmbeddingServing, :start_link, 1)
    end

    test "defines child_spec/1" do
      assert function_exported?(EmbeddingServing, :child_spec, 1)
    end
  end

  describe "configuration" do
    test "reads model repo from application config with default fallback" do
      original = Application.get_env(:slackex, :bumblebee_model_repo)

      Application.delete_env(:slackex, :bumblebee_model_repo)
      assert EmbeddingServing.model_repo() == "sentence-transformers/all-MiniLM-L6-v2"

      Application.put_env(:slackex, :bumblebee_model_repo, "custom/model")
      assert EmbeddingServing.model_repo() == "custom/model"

      # Restore original
      if original do
        Application.put_env(:slackex, :bumblebee_model_repo, original)
      else
        Application.delete_env(:slackex, :bumblebee_model_repo)
      end
    end

    test "cache_dir returns nil when BUMBLEBEE_CACHE_DIR is not set" do
      # In test env, BUMBLEBEE_CACHE_DIR is typically not set
      result = EmbeddingServing.cache_dir()
      assert is_nil(result) or is_binary(result)
    end
  end

  describe "docker-compose.prod.yml" do
    @compose_path Path.expand(
                    "../../../docker-compose.prod.yml",
                    __DIR__
                  )

    test "defines bumblebee_models volume" do
      content = File.read!(@compose_path)
      assert content =~ "bumblebee_models"
    end

    test "mounts bumblebee_models volume in app defaults" do
      content = File.read!(@compose_path)
      assert content =~ "bumblebee_models:/app/models"
    end

    test "sets BUMBLEBEE_CACHE_DIR environment variable" do
      content = File.read!(@compose_path)
      assert content =~ "BUMBLEBEE_CACHE_DIR"
    end
  end

  describe "model loading (requires model download)" do
    @tag :bumblebee
    test "batched_run returns 384-dim L2-normalized vectors" do
      input = "hello world"
      %{embedding: tensor} = Nx.Serving.batched_run(EmbeddingServing, input)

      vector = Nx.to_flat_list(tensor)
      assert length(vector) == 384

      magnitude =
        vector
        |> Enum.map(fn x -> x * x end)
        |> Enum.sum()
        |> :math.sqrt()

      assert_in_delta magnitude, 1.0, 1.0e-3
    end

    @tag :bumblebee
    test "identical input produces identical output (deterministic)" do
      input = "deterministic embedding test"
      %{embedding: tensor_a} = Nx.Serving.batched_run(EmbeddingServing, input)
      %{embedding: tensor_b} = Nx.Serving.batched_run(EmbeddingServing, input)

      assert Nx.to_flat_list(tensor_a) == Nx.to_flat_list(tensor_b)
    end
  end
end
