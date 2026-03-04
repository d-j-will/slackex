defmodule Slackex.Embeddings.EmbeddingServing do
  @moduledoc """
  Nx.Serving-based process for local embedding generation using Bumblebee.

  Loads sentence-transformers/all-MiniLM-L6-v2 (configurable) on init and
  serves batched embedding requests through `Nx.Serving.batched_run/2`.

  ## Configuration

      config :slackex, :bumblebee_model_repo, "sentence-transformers/all-MiniLM-L6-v2"

  ## Environment Variables

      BUMBLEBEE_CACHE_DIR - directory for caching downloaded model files

  ## Usage

      # Single text
      %{embedding: tensor} = Slackex.Embeddings.EmbeddingServing.run("hello world")
      vector = Nx.to_flat_list(tensor)

  Output vectors are 384-dimensional, L2-normalized, and deterministic.
  """

  use GenServer

  require Logger

  @default_model_repo "sentence-transformers/all-MiniLM-L6-v2"
  @serving_name :"#{__MODULE__}.Nx"

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc "Starts the EmbeddingServing process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs a batched embedding request against the loaded model."
  @spec run(String.t() | [String.t()]) :: map() | [map()]
  def run(input) do
    Nx.Serving.batched_run(@serving_name, input)
  end

  @doc "Returns the configured model repository identifier."
  @spec model_repo() :: String.t()
  def model_repo do
    Application.get_env(:slackex, :bumblebee_model_repo, @default_model_repo)
  end

  @doc "Returns the configured cache directory from the BUMBLEBEE_CACHE_DIR env var."
  @spec cache_dir() :: String.t() | nil
  def cache_dir do
    System.get_env("BUMBLEBEE_CACHE_DIR")
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{status: :loading}, {:continue, :load_model}}
  end

  @impl true
  def handle_continue(:load_model, _state) do
    repo = model_repo()
    cache = cache_dir()

    Logger.info("EmbeddingServing loading model #{repo}")

    case load_and_start_serving(repo, cache) do
      :ok ->
        Logger.info("EmbeddingServing ready (model: #{repo})")
        {:noreply, %{status: :ready, model_repo: repo}}

      {:error, reason} ->
        Logger.error("EmbeddingServing failed to load model: #{inspect(reason)}")
        {:noreply, %{status: :failed, error: reason}}
    end
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp load_and_start_serving(repo, cache) do
    hf_spec = build_hf_spec(repo, cache)

    {:ok, model_info} = Bumblebee.load_model(hf_spec)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(hf_spec)

    serving =
      Bumblebee.Text.text_embedding(model_info, tokenizer,
        output_attribute: :hidden_state,
        output_pool: :mean_pooling,
        embedding_processor: :l2_norm,
        compile: [batch_size: 64, sequence_length: 512],
        defn_options: [compiler: EXLA]
      )

    {:ok, _pid} =
      Nx.Serving.start_link(
        serving: serving,
        name: @serving_name,
        batch_timeout: 50
      )

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp build_hf_spec(repo, nil), do: {:hf, repo}
  defp build_hf_spec(repo, cache_dir), do: {:hf, repo, cache_dir: cache_dir}
end
