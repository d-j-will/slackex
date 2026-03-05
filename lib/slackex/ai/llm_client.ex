defmodule Slackex.AI.LLMClient do
  @moduledoc """
  Behaviour and delegation module for LLM chat completions.

  Defines the contract for LLM clients and delegates calls to the
  configured implementation via Application config.

  ## Configuration

      config :slackex, :llm_client, Slackex.AI.StubLLMClient

  ## Callbacks

  Implementations must provide:
  - `complete/2` — non-streaming chat completion
  - `stream/2` — streaming chat completion returning an Enumerable of token strings
  """

  @type message :: %{role: String.t(), content: String.t()}

  @callback complete(messages :: [message()], opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback stream(messages :: [message()], opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc "Sends a non-streaming chat completion request."
  @spec complete([message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts \\ []) do
    client().complete(messages, opts)
  end

  @doc "Sends a streaming chat completion request. Returns `{:ok, stream}` where stream yields token strings."
  @spec stream([message()], keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(messages, opts \\ []) do
    client().stream(messages, opts)
  end

  @doc "Returns true if an LLM client is configured and has an API key."
  @spec configured?() :: boolean()
  def configured? do
    client() != nil and Application.get_env(:slackex, :llm_api) != nil
  end

  defp client do
    Application.get_env(:slackex, :llm_client)
  end
end
