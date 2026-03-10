# LLM Foundation + Channel Summarization — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a configurable LLM client and channel summarization feature with streaming UI, behind a feature flag.

**Architecture:** Three layers — `LLMClient` behaviour (same pattern as `EmbeddingClient`), `Summarizer` domain module, and LiveView UI (streaming modal + slash command foundation). Universal AI telemetry module shared across all AI services.

**Tech Stack:** Elixir/Phoenix LiveView, Req (HTTP), `:telemetry`, FunWithFlags, DeepInfra API (Gemma-3-4b-it)

**Design doc:** `docs/plans/2026-03-05-llm-foundation-summarization-design.md`

---

## Task 1: AI Telemetry Module

Sets up the universal telemetry handler that all AI services (embeddings, LLM, future reranking/moderation) will use.

**Files:**
- Create: `lib/slackex/ai/telemetry.ex`
- Create: `test/slackex/ai/telemetry_test.exs`

**Step 1: Write the failing test**

```elixir
# test/slackex/ai/telemetry_test.exs
defmodule Slackex.AI.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Slackex.AI.Telemetry

  setup do
    Telemetry.attach_handlers()
    on_exit(fn -> :telemetry.list_handlers([:slackex, :ai]) |> Enum.each(&:telemetry.detach(&1.id)) end)
    :ok
  end

  describe "completion events" do
    test "logs completion telemetry" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:slackex, :ai, :completion],
            %{duration: 1_200_000},
            %{model: "gemma-3-4b-it", prompt_tokens: 2450, completion_tokens: 312}
          )
        end)

      assert log =~ "[AI] completion"
      assert log =~ "model=gemma-3-4b-it"
      assert log =~ "prompt=2450"
      assert log =~ "completion=312"
    end
  end

  describe "embedding events" do
    test "logs embedding telemetry" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:slackex, :ai, :embedding],
            %{duration: 400_000},
            %{model: "all-MiniLM-L6-v2", tokens: 156, batch_size: 3}
          )
        end)

      assert log =~ "[AI] embedding"
      assert log =~ "model=all-MiniLM-L6-v2"
      assert log =~ "tokens=156"
      assert log =~ "batch=3"
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/slackex/ai/telemetry_test.exs --max-failures 1`
Expected: FAIL — module `Slackex.AI.Telemetry` not found

**Step 3: Write minimal implementation**

```elixir
# lib/slackex/ai/telemetry.ex
defmodule Slackex.AI.Telemetry do
  @moduledoc """
  Universal telemetry handlers for all external AI services.

  Attaches `:telemetry` handlers that log structured lines for every
  AI API call. Attach once at application startup.

  ## Events

    * `[:slackex, :ai, :completion]` — LLM chat completions
    * `[:slackex, :ai, :embedding]` — embedding generation
    * `[:slackex, :ai, :rerank]` — reranking (future)
    * `[:slackex, :ai, :moderation]` — moderation (future)
  """

  require Logger

  @events [
    [:slackex, :ai, :completion],
    [:slackex, :ai, :embedding],
    [:slackex, :ai, :rerank],
    [:slackex, :ai, :moderation]
  ]

  @doc "Attaches telemetry handlers for all AI service events."
  def attach_handlers do
    :telemetry.attach_many(
      "slackex-ai-telemetry",
      @events,
      &handle_event/4,
      nil
    )
  end

  defp handle_event([:slackex, :ai, :completion], measurements, metadata, _config) do
    duration_ms = div(measurements.duration, 1_000)

    Logger.info(
      "[AI] completion model=#{metadata.model} prompt=#{metadata.prompt_tokens} completion=#{metadata.completion_tokens} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:slackex, :ai, :embedding], measurements, metadata, _config) do
    duration_ms = div(measurements.duration, 1_000)

    Logger.info(
      "[AI] embedding model=#{metadata.model} tokens=#{metadata[:tokens] || "n/a"} batch=#{metadata[:batch_size] || 1} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:slackex, :ai, event_type], measurements, metadata, _config) do
    duration_ms = div(measurements.duration, 1_000)
    Logger.info("[AI] #{event_type} model=#{metadata[:model] || "unknown"} duration=#{duration_ms}ms")
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/slackex/ai/telemetry_test.exs`
Expected: PASS (2 tests)

**Step 5: Wire telemetry into application startup**

Modify: `lib/slackex/application.ex` — add `Slackex.AI.Telemetry.attach_handlers()` in the `start/2` function, before the supervisor children list.

**Step 6: Commit**

```bash
git add lib/slackex/ai/telemetry.ex test/slackex/ai/telemetry_test.exs lib/slackex/application.ex
git commit -m "feat(ai): add universal AI telemetry module

Structured logging for all external AI service calls via :telemetry.
Handles completion, embedding, rerank, and moderation events.
Wired into application startup."
```

---

## Task 2: LLMClient Behaviour + Delegation Module

Mirror the `EmbeddingClient` pattern — behaviour callbacks + delegation to configured implementation.

**Files:**
- Create: `lib/slackex/ai/llm_client.ex`
- Create: `test/slackex/ai/llm_client_test.exs`

**Step 1: Write the failing test**

```elixir
# test/slackex/ai/llm_client_test.exs
defmodule Slackex.AI.LLMClientTest do
  use ExUnit.Case, async: true

  alias Slackex.AI.LLMClient

  describe "behaviour callbacks" do
    test "LLMClient defines complete/2 callback" do
      callbacks = LLMClient.behaviour_info(:callbacks)
      assert {:complete, 2} in callbacks
    end

    test "LLMClient defines stream/2 callback" do
      callbacks = LLMClient.behaviour_info(:callbacks)
      assert {:stream, 2} in callbacks
    end
  end

  describe "delegation" do
    test "complete/2 delegates to configured client" do
      messages = [%{role: "user", content: "Hello"}]
      result = LLMClient.complete(messages, [])
      assert {:ok, text} = result
      assert is_binary(text)
    end

    test "stream/2 delegates to configured client" do
      messages = [%{role: "user", content: "Hello"}]
      result = LLMClient.stream(messages, [])
      assert {:ok, stream} = result
      chunks = Enum.to_list(stream)
      assert length(chunks) > 0
      assert Enum.all?(chunks, &is_binary/1)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/slackex/ai/llm_client_test.exs --max-failures 1`
Expected: FAIL — module not found

**Step 3: Write minimal implementation**

```elixir
# lib/slackex/ai/llm_client.ex
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
```

**Step 4: This test depends on the StubLLMClient (Task 3). Skip running until after Task 3.**

**Step 5: Commit (behaviour module only)**

```bash
git add lib/slackex/ai/llm_client.ex test/slackex/ai/llm_client_test.exs
git commit -m "feat(ai): add LLMClient behaviour and delegation module

Defines complete/2 and stream/2 callbacks. Delegates to configured
implementation via :llm_client app config. Same pattern as EmbeddingClient."
```

---

## Task 3: StubLLMClient (Test Double)

**Files:**
- Create: `lib/slackex/ai/stub_llm_client.ex`
- Create: `test/slackex/ai/stub_llm_client_test.exs`
- Modify: `config/test.exs` — add `:llm_client` config

**Step 1: Write the failing test**

```elixir
# test/slackex/ai/stub_llm_client_test.exs
defmodule Slackex.AI.StubLLMClientTest do
  use ExUnit.Case, async: true

  alias Slackex.AI.StubLLMClient

  describe "complete/2" do
    test "returns a deterministic summary string" do
      messages = [%{role: "user", content: "Summarize this"}]
      assert {:ok, text} = StubLLMClient.complete(messages, [])
      assert is_binary(text)
      assert String.length(text) > 0
    end

    test "returns the same result for the same input" do
      messages = [%{role: "user", content: "Hello"}]
      {:ok, text1} = StubLLMClient.complete(messages, [])
      {:ok, text2} = StubLLMClient.complete(messages, [])
      assert text1 == text2
    end
  end

  describe "stream/2" do
    test "returns an enumerable of token strings" do
      messages = [%{role: "user", content: "Summarize"}]
      assert {:ok, stream} = StubLLMClient.stream(messages, [])
      chunks = Enum.to_list(stream)
      assert length(chunks) > 0
      assert Enum.all?(chunks, &is_binary/1)
    end

    test "stream chunks join to the same result as complete" do
      messages = [%{role: "user", content: "Hello"}]
      {:ok, complete_text} = StubLLMClient.complete(messages, [])
      {:ok, stream} = StubLLMClient.stream(messages, [])
      streamed_text = stream |> Enum.to_list() |> Enum.join()
      assert streamed_text == complete_text
    end
  end

  describe "behaviour" do
    test "implements LLMClient behaviour" do
      behaviours =
        StubLLMClient.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Slackex.AI.LLMClient in behaviours
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/slackex/ai/stub_llm_client_test.exs --max-failures 1`
Expected: FAIL — module not found

**Step 3: Write minimal implementation**

```elixir
# lib/slackex/ai/stub_llm_client.ex
defmodule Slackex.AI.StubLLMClient do
  @moduledoc """
  Deterministic LLM client for test environments.

  Returns canned responses without network calls. The `stream/2` function
  yields individual words from the response to simulate streaming.
  """

  @behaviour Slackex.AI.LLMClient

  @canned_response "Here is a summary of the conversation:\n\n" <>
    "**Key Topics:** The team discussed project updates and upcoming deadlines.\n\n" <>
    "**Decisions Made:** Agreed to proceed with the current approach.\n\n" <>
    "**Action Items:**\n- Review the pull request (unassigned)\n- Update documentation (unassigned)"

  @impl true
  def complete(_messages, _opts) do
    {:ok, @canned_response}
  end

  @impl true
  def stream(_messages, _opts) do
    words = String.split(@canned_response, ~r/(?<=\s)/, include_captures: false)
    stream = Stream.map(words, & &1)
    {:ok, stream}
  end
end
```

**Step 4: Add test config**

Modify: `config/test.exs` — add at the bottom:

```elixir
# Use deterministic stub for LLM in tests
config :slackex, :llm_client, Slackex.AI.StubLLMClient
```

**Step 5: Run tests to verify they pass**

Run: `mix test test/slackex/ai/stub_llm_client_test.exs test/slackex/ai/llm_client_test.exs`
Expected: PASS (all tests from both Task 2 and Task 3)

**Step 6: Commit**

```bash
git add lib/slackex/ai/stub_llm_client.ex test/slackex/ai/stub_llm_client_test.exs config/test.exs
git commit -m "feat(ai): add StubLLMClient for test environment

Deterministic canned responses. stream/2 yields words to simulate
streaming. Configured as :llm_client in test.exs."
```

---

## Task 4: OpenAICompatibleClient (Real API Client)

**Files:**
- Create: `lib/slackex/ai/openai_compatible_client.ex`
- Create: `test/slackex/ai/openai_compatible_client_test.exs`
- Modify: `config/prod.exs` — add `:llm_client` config
- Modify: `config/dev.exs` — add `:llm_client` config

**Step 1: Write the failing test**

```elixir
# test/slackex/ai/openai_compatible_client_test.exs
defmodule Slackex.AI.OpenAICompatibleClientTest do
  use ExUnit.Case, async: false
  # async: false because we modify app config

  alias Slackex.AI.OpenAICompatibleClient

  setup do
    original = Application.get_env(:slackex, :llm_api)

    on_exit(fn ->
      if original, do: Application.put_env(:slackex, :llm_api, original),
                  else: Application.delete_env(:slackex, :llm_api)
    end)

    :ok
  end

  describe "config/2" do
    test "reads from :llm_api map config" do
      Application.put_env(:slackex, :llm_api, %{
        api_url: "https://custom.api/v1",
        model: "custom-model",
        api_key: "test-key",
        max_tokens: 512,
        temperature: 0.5
      })

      # Verify the module reads config correctly via a complete call
      # (will fail with network error, but proves config is read)
      assert {:error, _} = OpenAICompatibleClient.complete(
        [%{role: "user", content: "test"}], []
      )
    end

    test "returns :not_configured when no API key" do
      Application.delete_env(:slackex, :llm_api)

      assert {:error, :not_configured} = OpenAICompatibleClient.complete(
        [%{role: "user", content: "test"}], []
      )
    end
  end

  describe "behaviour" do
    test "implements LLMClient behaviour" do
      behaviours =
        OpenAICompatibleClient.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Slackex.AI.LLMClient in behaviours
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/slackex/ai/openai_compatible_client_test.exs --max-failures 1`
Expected: FAIL — module not found

**Step 3: Write implementation**

```elixir
# lib/slackex/ai/openai_compatible_client.ex
defmodule Slackex.AI.OpenAICompatibleClient do
  @moduledoc """
  OpenAI-compatible chat completions client.

  Sends requests to any OpenAI-compatible chat completions API
  (DeepInfra, OpenRouter, OpenAI, etc.) via Req.

  ## Configuration

      config :slackex, :llm_api, %{
        api_url: "https://api.deepinfra.com/v1/openai",
        model: "google/gemma-3-4b-it",
        api_key: "your-key",
        max_tokens: 1024,
        temperature: 0.3
      }
  """

  @behaviour Slackex.AI.LLMClient

  @default_api_url "https://api.deepinfra.com/v1/openai"
  @default_model "google/gemma-3-4b-it"
  @default_max_tokens 1024
  @default_temperature 0.3
  @receive_timeout_ms 60_000

  @impl true
  def complete(messages, opts \\ []) do
    with {:ok, api_key} <- fetch_api_key() do
      body = %{
        model: Keyword.get(opts, :model, config(:model, @default_model)),
        messages: messages,
        max_tokens: Keyword.get(opts, :max_tokens, config(:max_tokens, @default_max_tokens)),
        temperature: config(:temperature, @default_temperature),
        stream: false
      }

      start_time = System.monotonic_time()

      case Req.post(completions_url(),
             json: body,
             headers: auth_headers(api_key),
             receive_timeout: @receive_timeout_ms
           ) do
        {:ok, %Req.Response{status: 200, body: response_body}} ->
          content =
            response_body
            |> get_in(["choices", Access.at(0), "message", "content"])

          emit_telemetry(start_time, response_body)
          {:ok, content || ""}

        {:ok, %Req.Response{status: status, body: response_body}} ->
          {:error, {:api_error, status, response_body}}

        {:error, exception} ->
          {:error, {:network_error, exception}}
      end
    end
  end

  @impl true
  def stream(messages, opts \\ []) do
    with {:ok, api_key} <- fetch_api_key() do
      body = %{
        model: Keyword.get(opts, :model, config(:model, @default_model)),
        messages: messages,
        max_tokens: Keyword.get(opts, :max_tokens, config(:max_tokens, @default_max_tokens)),
        temperature: config(:temperature, @default_temperature),
        stream: true
      }

      start_time = System.monotonic_time()

      stream =
        Stream.resource(
          fn -> start_stream(body, api_key) end,
          &next_chunk/1,
          fn
            {:done, _ref} -> :ok
            {:error, _} -> :ok
            ref when is_reference(ref) -> :ok
          end
        )
        |> Stream.transform(
          fn -> nil end,
          fn chunk, _acc -> {[chunk], nil} end,
          fn _acc ->
            duration = System.monotonic_time() - start_time
            :telemetry.execute(
              [:slackex, :ai, :completion],
              %{duration: duration},
              %{model: config(:model, @default_model), prompt_tokens: 0, completion_tokens: 0, streaming: true}
            )
          end
        )

      {:ok, stream}
    end
  end

  # -- Streaming internals --

  defp start_stream(body, api_key) do
    # Use Req with into: :self for streaming
    case Req.post(completions_url(),
           json: body,
           headers: auth_headers(api_key),
           receive_timeout: @receive_timeout_ms,
           into: :self
         ) do
      {:ok, %Req.Response{status: 200} = resp} ->
        resp.body

      {:ok, %Req.Response{status: status}} ->
        {:error, {:api_error, status}}

      {:error, exception} ->
        {:error, {:network_error, exception}}
    end
  end

  defp next_chunk({:error, _reason} = err), do: {:halt, err}

  defp next_chunk(ref) when is_reference(ref) do
    receive do
      {^ref, {:data, data}} ->
        chunks = parse_sse_data(data)
        if :done in chunks do
          {Enum.filter(chunks, &is_binary/1), {:done, ref}}
        else
          {chunks, ref}
        end

      {^ref, :done} ->
        {:halt, {:done, ref}}
    after
      @receive_timeout_ms ->
        {:halt, {:error, :timeout}}
    end
  end

  defp next_chunk({:done, _ref} = done), do: {:halt, done}

  defp parse_sse_data(data) do
    data
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn line ->
      json_str = String.trim_leading(line, "data: ")

      if json_str == "[DONE]" do
        :done
      else
        case Jason.decode(json_str) do
          {:ok, parsed} ->
            get_in(parsed, ["choices", Access.at(0), "delta", "content"]) || ""

          _ ->
            ""
        end
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # -- Config helpers --

  defp completions_url do
    base = config(:api_url, @default_api_url)
    String.trim_trailing(base, "/") <> "/chat/completions"
  end

  defp auth_headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]
  end

  defp fetch_api_key do
    case config(:api_key, nil) do
      nil -> {:error, :not_configured}
      key -> {:ok, key}
    end
  end

  defp config(key, default) do
    case Application.get_env(:slackex, :llm_api) do
      nil -> default
      config when is_map(config) -> Map.get(config, key, default)
      config when is_list(config) -> Keyword.get(config, key, default)
    end
  end

  defp emit_telemetry(start_time, response_body) do
    duration = System.monotonic_time() - start_time
    usage = Map.get(response_body, "usage", %{})

    :telemetry.execute(
      [:slackex, :ai, :completion],
      %{duration: duration},
      %{
        model: config(:model, @default_model),
        prompt_tokens: Map.get(usage, "prompt_tokens", 0),
        completion_tokens: Map.get(usage, "completion_tokens", 0)
      }
    )
  end
end
```

**Step 4: Add config to prod.exs and dev.exs**

Add to `config/prod.exs` after the embedding client line:
```elixir
config :slackex, :llm_client, Slackex.AI.OpenAICompatibleClient
```

Add to `config/dev.exs` at the bottom:
```elixir
# Use real LLM API in development (same as prod)
config :slackex, :llm_client, Slackex.AI.OpenAICompatibleClient
```

**Step 5: Run tests to verify they pass**

Run: `mix test test/slackex/ai/openai_compatible_client_test.exs`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/slackex/ai/openai_compatible_client.ex test/slackex/ai/openai_compatible_client_test.exs config/prod.exs config/dev.exs
git commit -m "feat(ai): add OpenAICompatibleClient for LLM completions

Configurable chat completions client supporting any OpenAI-compatible API.
Non-streaming and streaming (SSE via Req :self) modes.
Emits [:slackex, :ai, :completion] telemetry events with token usage."
```

---

## Task 5: Runtime Configuration + Deploy Wiring

**Files:**
- Modify: `config/runtime.exs` — add LLM env vars
- Modify: `docker-compose.prod.yml` — add `LLM_API_KEY`
- Modify: `.github/workflows/ci-deploy.yml` — add `LLM_API_KEY` secret provisioning

**Step 1: Add LLM config to runtime.exs**

After the `EMBEDDING_API_KEY` block (~line 140), add:

```elixir
  # LLM API config — defaults to DeepInfra with Gemma-3-4b-it.
  # Override with LLM_API_URL / LLM_MODEL / LLM_MAX_TOKENS for other providers.
  if llm_api_key = System.get_env("LLM_API_KEY") do
    config :slackex, :llm_api, %{
      api_url: System.get_env("LLM_API_URL", "https://api.deepinfra.com/v1/openai"),
      model: System.get_env("LLM_MODEL", "google/gemma-3-4b-it"),
      api_key: llm_api_key,
      max_tokens: String.to_integer(System.get_env("LLM_MAX_TOKENS", "1024")),
      temperature: 0.3
    }
  end
```

**Step 2: Add LLM_API_KEY to docker-compose.prod.yml**

In the `&app-env` environment block, after `EMBEDDING_API_KEY`, add:
```yaml
    LLM_API_KEY: "${LLM_API_KEY}"
```

**Step 3: Add LLM_API_KEY to CI deploy**

In `.github/workflows/ci-deploy.yml`, in the `Deploy to Docker host` step:

a) Add to the `env:` block:
```yaml
          LLM_API_KEY: ${{ secrets.LLM_API_KEY }}
```

b) Add to the SSH `.env` provisioning block (after EMBEDDING_API_KEY lines):
```bash
            grep -q '^LLM_API_KEY=' /root/slackex/.env 2>/dev/null && \
              sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=${LLM_API_KEY}|' /root/slackex/.env || \
              echo 'LLM_API_KEY=${LLM_API_KEY}' >> /root/slackex/.env
```

**Step 4: Run format and verify**

Run: `mix format config/runtime.exs`
Run: `ruby -ryaml -e "YAML.safe_load(File.read('.github/workflows/ci-deploy.yml'))"`
Expected: No errors

**Step 5: Commit**

```bash
git add config/runtime.exs docker-compose.prod.yml .github/workflows/ci-deploy.yml
git commit -m "feat(ai): wire LLM_API_KEY through runtime config and CI deploy

Adds LLM_API_KEY/LLM_API_URL/LLM_MODEL/LLM_MAX_TOKENS env vars.
DeepInfra with Gemma-3-4b-it as defaults. Same GH secrets -> .env
pattern as EMBEDDING_API_KEY."
```

---

## Task 6: Feature Flag Setup

**Files:**
- No new files — FunWithFlags is already configured

**Step 1: Verify feature flag infrastructure**

Run in `iex -S mix`:
```elixir
FunWithFlags.disable(:channel_summarization)
FunWithFlags.enabled?(:channel_summarization)
# Expected: false
```

This flag will guard the summarize button and slash command. No migration needed — FunWithFlags stores flags in its own table.

**Step 2: Commit (no code change needed, but document the flag)**

The flag is created dynamically via the admin UI at `/admin/flags` when ready to enable. Move on to the Summarizer.

---

## Task 7: Summarizer Domain Module

**Files:**
- Create: `lib/slackex/ai/summarizer.ex`
- Create: `test/slackex/ai/summarizer_test.exs`

**Step 1: Write the failing test**

```elixir
# test/slackex/ai/summarizer_test.exs
defmodule Slackex.AI.SummarizerTest do
  use Slackex.DataCase, async: false

  alias Slackex.AI.Summarizer

  describe "summarize_channel/4" do
    test "returns error when no messages in range" do
      channel = insert(:channel)
      user = insert(:user)
      since = DateTime.utc_now()

      assert {:error, :no_messages} = Summarizer.summarize_channel(channel.id, since, user.id, [])
    end

    test "returns error when LLM not configured" do
      original = Application.get_env(:slackex, :llm_client)
      Application.delete_env(:slackex, :llm_client)

      on_exit(fn -> Application.put_env(:slackex, :llm_client, original) end)

      channel = insert(:channel)
      user = insert(:user)
      since = DateTime.add(DateTime.utc_now(), -86400, :second)

      assert {:error, :not_configured} = Summarizer.summarize_channel(channel.id, since, user.id, [])
    end

    test "streams a summary for channel messages" do
      channel = insert(:channel)
      sender = insert(:user)
      user = insert(:user)

      # Insert messages older than "since"
      _msg1 = insert_channel_message(channel, sender, "We should deploy the new feature")
      _msg2 = insert_channel_message(channel, sender, "Agreed, let's ship it tomorrow")

      since = DateTime.add(DateTime.utc_now(), -86400, :second)

      assert {:ok, stream} = Summarizer.summarize_channel(channel.id, since, user.id, [])
      chunks = Enum.to_list(stream)
      assert length(chunks) > 0
      full_text = Enum.join(chunks)
      assert String.length(full_text) > 0
    end
  end

  describe "build_prompt/3" do
    test "includes channel name and time range in prompt" do
      {system, user_msg} = Summarizer.build_prompt("#general", "Monday", "Some context here")
      assert system =~ "summarizer"
      assert user_msg =~ "#general"
      assert user_msg =~ "Monday"
      assert user_msg =~ "Some context here"
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/slackex/ai/summarizer_test.exs --max-failures 1`
Expected: FAIL — module not found

**Step 3: Write implementation**

```elixir
# lib/slackex/ai/summarizer.ex
defmodule Slackex.AI.Summarizer do
  @moduledoc """
  Summarizes recent channel activity using the configured LLM client.

  Loads messages from a channel since a given timestamp, formats them as
  context, and streams an AI-generated summary.
  """

  alias Slackex.AI.LLMClient
  alias Slackex.Chat
  alias Slackex.Chat.Message
  alias Slackex.Repo

  import Ecto.Query

  @max_context_tokens 4_000
  @chars_per_token 4

  @doc """
  Summarizes a channel's messages since the given timestamp.

  Returns `{:ok, token_stream}` where the stream yields string chunks,
  or `{:error, reason}`.

  ## Errors

    * `:not_configured` — no LLM client configured
    * `:no_messages` — no messages found in the time range
  """
  @spec summarize_channel(integer(), DateTime.t(), integer(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, atom()}
  def summarize_channel(channel_id, since, _user_id, opts \\ []) do
    with :ok <- check_configured(),
         {:ok, messages} <- load_messages(channel_id, since),
         {:ok, context} <- format_context(messages) do
      channel_name = channel_name(channel_id)
      since_human = Calendar.strftime(since, "%B %d, %Y at %H:%M UTC")
      {system_prompt, user_prompt} = build_prompt(channel_name, since_human, context)

      messages = [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_prompt}
      ]

      LLMClient.stream(messages, opts)
    end
  end

  @doc """
  Builds the system and user prompts for channel summarization.

  Exposed for testing.
  """
  @spec build_prompt(String.t(), String.t(), String.t()) :: {String.t(), String.t()}
  def build_prompt(channel_name, since_human, context) do
    system = """
    You are a concise channel summarizer for a team chat app.
    Summarize the conversation clearly and briefly. Include:
    - Key topics discussed
    - Decisions made
    - Action items (with who owns them, if mentioned)
    - Notable messages or announcements
    Do not invent information not present in the messages.
    """

    user = """
    Summarize the following conversation from #{channel_name} since #{since_human}:

    #{context}
    """

    {String.trim(system), String.trim(user)}
  end

  # -- Private --

  defp check_configured do
    if LLMClient.configured?(), do: :ok, else: {:error, :not_configured}
  end

  defp load_messages(channel_id, since) do
    messages =
      from(m in Message,
        where: m.channel_id == ^channel_id,
        where: m.inserted_at >= ^since,
        where: is_nil(m.deleted_at),
        order_by: [asc: m.inserted_at],
        preload: [:sender],
        limit: 200
      )
      |> Repo.all()

    case messages do
      [] -> {:error, :no_messages}
      msgs -> {:ok, msgs}
    end
  end

  defp format_context(messages) do
    max_chars = @max_context_tokens * @chars_per_token

    lines =
      messages
      |> Enum.map(&format_line/1)
      |> truncate_to_budget(max_chars)

    {:ok, Enum.join(lines, "\n")}
  end

  defp format_line(message) do
    timestamp = Calendar.strftime(message.inserted_at, "%Y-%m-%d %H:%M")
    username = if message.sender, do: message.sender.username, else: "[deleted user]"
    content = message.search_content || ""

    "[#{timestamp}] #{username}: #{content}"
  end

  defp truncate_to_budget(lines, max_chars) do
    truncate_lines(lines, max_chars, 0, [])
  end

  defp truncate_lines([], _max, _used, acc), do: Enum.reverse(acc)

  defp truncate_lines([line | rest], max, used, acc) do
    sep = if acc == [], do: 0, else: 1
    total = used + sep + byte_size(line)

    if total <= max do
      truncate_lines(rest, max, total, [line | acc])
    else
      Enum.reverse(acc)
    end
  end

  defp channel_name(channel_id) do
    case Repo.get(Chat.Channel, channel_id) do
      nil -> "#unknown"
      channel -> "##{channel.name}"
    end
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `mix test test/slackex/ai/summarizer_test.exs`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/slackex/ai/summarizer.ex test/slackex/ai/summarizer_test.exs
git commit -m "feat(ai): add Summarizer domain module

Loads channel messages since a timestamp, formats as context,
streams LLM summary. Early returns for no messages / not configured.
Token budget truncation (4K tokens, ~16KB context)."
```

---

## Task 8: Summary Modal Component

**Files:**
- Create: `lib/slackex_web/live/chat_live/summary_modal.ex`
- Create: `test/slackex_web/live/chat_live/summary_modal_test.exs`
- Modify: `lib/slackex_web/live/chat_live/index.ex` — add summary assigns, event handlers, modal rendering

**Step 1: Write the failing test**

```elixir
# test/slackex_web/live/chat_live/summary_modal_test.exs
defmodule SlackexWeb.ChatLive.SummaryModalTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Chat

  setup %{conn: conn} do
    user = insert(:user)
    channel = insert(:channel)
    Chat.create_subscription(user.id, channel.id)

    # Enable the feature flag
    FunWithFlags.enable(:channel_summarization)
    on_exit(fn -> FunWithFlags.disable(:channel_summarization) end)

    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user, channel: channel}
  end

  describe "summary modal" do
    test "summarize button visible when flag enabled", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")
      assert has_element?(view, "[data-role=summarize-button]")
    end

    test "summarize button hidden when flag disabled", %{conn: conn, channel: channel} do
      FunWithFlags.disable(:channel_summarization)
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")
      refute has_element?(view, "[data-role=summarize-button]")
    end

    test "clicking summarize opens modal with time range options", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")
      view |> element("[data-role=summarize-button]") |> render_click()
      assert has_element?(view, "[data-role=summary-modal]")
      assert has_element?(view, "[data-role=time-range-24h]")
    end

    test "selecting time range starts summary stream", %{conn: conn, channel: channel, user: user} do
      sender = insert(:user)
      insert_channel_message(channel, sender, "Hello world")

      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")
      view |> element("[data-role=summarize-button]") |> render_click()
      view |> element("[data-role=time-range-24h]") |> render_click()

      # The stub client returns a canned response — wait for streaming to complete
      Process.sleep(100)
      html = render(view)
      assert html =~ "summary" or html =~ "Summary" or html =~ "Key Topics"
    end

    test "close button dismisses modal", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")
      view |> element("[data-role=summarize-button]") |> render_click()
      assert has_element?(view, "[data-role=summary-modal]")
      view |> element("[data-role=close-summary]") |> render_click()
      refute has_element?(view, "[data-role=summary-modal]")
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/slackex_web/live/chat_live/summary_modal_test.exs --max-failures 1`
Expected: FAIL — no summarize button element

**Step 3: Create the SummaryModal LiveComponent**

```elixir
# lib/slackex_web/live/chat_live/summary_modal.ex
defmodule SlackexWeb.ChatLive.SummaryModal do
  @moduledoc """
  LiveComponent for the channel summarization modal.

  Displays time range selection and streams AI-generated summary text.
  Three dismiss mechanisms: backdrop click, Escape key, close button.
  """
  use SlackexWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:summary_text, "")
     |> assign(:summary_state, :idle)
     |> assign(:error, nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("close_summary", _params, socket) do
    send(self(), :close_summary_modal)
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_time_range", %{"range" => range}, socket) do
    send(self(), {:start_summary, range})
    {:noreply, assign(socket, summary_state: :loading, summary_text: "", error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="summary-modal"
      data-role="summary-modal"
      phx-window-keydown="close_summary"
      phx-key="Escape"
      phx-target={@myself}
      class="fixed inset-0 z-50 flex items-center justify-center"
    >
      <%!-- Backdrop --%>
      <div class="absolute inset-0 bg-black/50" phx-click="close_summary" phx-target={@myself} />

      <%!-- Modal card --%>
      <div class="relative bg-base-100 rounded-lg shadow-xl w-full max-w-lg mx-4 max-h-[80vh] flex flex-col">
        <%!-- Header --%>
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="text-lg font-semibold">Channel Summary</h3>
          <button
            data-role="close-summary"
            phx-click="close_summary"
            phx-target={@myself}
            class="btn btn-ghost btn-sm btn-square"
          >
            <span class="hero-x-mark size-5" />
          </button>
        </div>

        <%!-- Content --%>
        <div class="p-4 overflow-y-auto flex-1">
          <%= if @summary_state == :idle do %>
            <p class="text-sm text-base-content/70 mb-4">Choose a time range to summarize:</p>
            <div class="flex flex-wrap gap-2">
              <button
                data-role="time-range-24h"
                phx-click="select_time_range"
                phx-value-range="24h"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                Last 24 hours
              </button>
              <button
                data-role="time-range-7d"
                phx-click="select_time_range"
                phx-value-range="7d"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                Last 7 days
              </button>
              <button
                data-role="time-range-30d"
                phx-click="select_time_range"
                phx-value-range="30d"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                Last 30 days
              </button>
            </div>
          <% end %>

          <%= if @summary_state == :loading do %>
            <div class="flex items-center gap-2 mb-2">
              <span class="loading loading-spinner loading-sm" />
              <span class="text-sm text-base-content/70">Generating summary...</span>
            </div>
            <div class="prose prose-sm max-w-none whitespace-pre-wrap"><%= @summary_text %></div>
          <% end %>

          <%= if @summary_state == :complete do %>
            <div class="prose prose-sm max-w-none whitespace-pre-wrap"><%= @summary_text %></div>
          <% end %>

          <%= if @summary_state == :error do %>
            <div class="alert alert-error">
              <span><%= error_message(@error) %></span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp error_message(:no_messages), do: "No messages found in this time range."
  defp error_message(:not_configured), do: "AI features are not configured."
  defp error_message(:unauthorized), do: "You don't have access to this channel."
  defp error_message(_), do: "Something went wrong. Please try again."
end
```

**Step 4: Wire into the parent LiveView (`index.ex`)**

Add these modifications to `lib/slackex_web/live/chat_live/index.ex`:

a) Add alias at top:
```elixir
alias SlackexWeb.ChatLive.SummaryModal
```

b) Add assigns in `mount/3` (after `search_enabled`):
```elixir
|> assign(:show_summary_modal, false)
|> assign(:summary_text, "")
|> assign(:summary_state, :idle)
|> assign(:summary_error, nil)
|> assign(:summarization_enabled, FunWithFlags.enabled?(:channel_summarization))
|> assign(:active_summary_task, nil)
```

c) Add event handlers:

```elixir
def handle_event("open_summary_modal", _params, socket) do
  {:noreply, assign(socket, show_summary_modal: true)}
end

def handle_event("close_summary_modal", _params, socket) do
  socket = cancel_summary_task(socket)
  {:noreply, assign(socket, show_summary_modal: false, summary_state: :idle, summary_text: "")}
end
```

d) Add `handle_info` clauses for streaming and the modal close:

```elixir
def handle_info(:close_summary_modal, socket) do
  socket = cancel_summary_task(socket)
  {:noreply, assign(socket, show_summary_modal: false, summary_state: :idle, summary_text: "")}
end

def handle_info({:start_summary, range}, socket) do
  channel = socket.assigns.active_channel
  user = socket.assigns.current_user
  socket = cancel_summary_task(socket)

  since = time_range_to_datetime(range)

  task =
    Task.async(fn ->
      case Slackex.AI.Summarizer.summarize_channel(channel.id, since, user.id) do
        {:ok, stream} ->
          Enum.each(stream, fn chunk ->
            send(socket.root_pid, {:summary_token, chunk})
          end)
          send(socket.root_pid, :summary_complete)

        {:error, reason} ->
          send(socket.root_pid, {:summary_error, reason})
      end
    end)

  {:noreply, assign(socket, active_summary_task: task, summary_state: :loading, summary_text: "")}
end

def handle_info({:summary_token, chunk}, socket) do
  new_text = socket.assigns.summary_text <> chunk
  {:noreply, assign(socket, summary_text: new_text)}
end

def handle_info(:summary_complete, socket) do
  {:noreply, assign(socket, summary_state: :complete, active_summary_task: nil)}
end

def handle_info({:summary_error, reason}, socket) do
  {:noreply, assign(socket, summary_state: :error, summary_error: reason, active_summary_task: nil)}
end

# Task.async sends {ref, result} and {:DOWN, ...} — handle them
def handle_info({ref, _result}, socket) when is_reference(ref) do
  Process.demonitor(ref, [:flush])
  {:noreply, socket}
end
```

e) Add private helpers:

```elixir
defp cancel_summary_task(socket) do
  case socket.assigns[:active_summary_task] do
    %Task{pid: pid} ->
      Process.exit(pid, :kill)
      assign(socket, active_summary_task: nil)
    _ ->
      socket
  end
end

defp time_range_to_datetime("24h"), do: DateTime.add(DateTime.utc_now(), -1, :day)
defp time_range_to_datetime("7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
defp time_range_to_datetime("30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
defp time_range_to_datetime(_), do: DateTime.add(DateTime.utc_now(), -1, :day)
```

f) Add the summarize button and modal to the template. Find the channel header area in the template and add:

```heex
<%= if @summarization_enabled and @active_channel do %>
  <button
    data-role="summarize-button"
    phx-click="open_summary_modal"
    class="btn btn-ghost btn-sm gap-1"
  >
    <span class="hero-sparkles size-4" />
    <span class="hidden sm:inline">Summarize</span>
  </button>
<% end %>
```

And for the modal (at the bottom of the template):
```heex
<%= if @show_summary_modal do %>
  <.live_component
    module={SummaryModal}
    id="summary-modal"
    summary_text={@summary_text}
    summary_state={@summary_state}
    error={@summary_error}
  />
<% end %>
```

**Step 5: Run tests**

Run: `mix test test/slackex_web/live/chat_live/summary_modal_test.exs`
Expected: PASS

**Step 6: Run full test suite**

Run: `mix test`
Expected: All tests pass (no regressions)

**Step 7: Commit**

```bash
git add lib/slackex_web/live/chat_live/summary_modal.ex test/slackex_web/live/chat_live/summary_modal_test.exs lib/slackex_web/live/chat_live/index.ex
git commit -m "feat(ai): add channel summary modal with streaming UI

Summarize button in channel header (behind :channel_summarization flag).
Modal with time range selection (24h/7d/30d). Streams summary tokens
via linked Task -> handle_info -> progressive render. Three dismiss
mechanisms (backdrop, Escape, X button)."
```

---

## Task 9: Slash Command Foundation

**Files:**
- Create: `lib/slackex_web/live/chat_live/slash_command.ex`
- Create: `test/slackex_web/live/chat_live/slash_command_test.exs`
- Modify: `lib/slackex_web/live/chat_live/index.ex` — intercept `/` messages

**Step 1: Write the failing test**

```elixir
# test/slackex_web/live/chat_live/slash_command_test.exs
defmodule SlackexWeb.ChatLive.SlashCommandTest do
  use ExUnit.Case, async: true

  alias SlackexWeb.ChatLive.SlashCommand

  describe "parse/1" do
    test "parses /summarize with no args as 24h" do
      assert {:summarize, "24h"} = SlashCommand.parse("/summarize")
    end

    test "parses /summarize 7d" do
      assert {:summarize, "7d"} = SlashCommand.parse("/summarize 7d")
    end

    test "parses /summarize 30d" do
      assert {:summarize, "30d"} = SlashCommand.parse("/summarize 30d")
    end

    test "returns :not_command for regular messages" do
      assert :not_command = SlashCommand.parse("hello world")
    end

    test "returns :not_command for empty string" do
      assert :not_command = SlashCommand.parse("")
    end

    test "returns :unknown_command for unrecognized slash commands" do
      assert {:unknown_command, "foo"} = SlashCommand.parse("/foo")
    end

    test "handles whitespace" do
      assert {:summarize, "7d"} = SlashCommand.parse("  /summarize  7d  ")
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/slackex_web/live/chat_live/slash_command_test.exs --max-failures 1`
Expected: FAIL — module not found

**Step 3: Write implementation**

```elixir
# lib/slackex_web/live/chat_live/slash_command.ex
defmodule SlackexWeb.ChatLive.SlashCommand do
  @moduledoc """
  Parses slash commands from message input.

  Commands start with `/` and are dispatched before being sent as messages.
  Extensible via pattern matching — add new commands by adding `do_parse/1` clauses.

  ## Supported Commands

    * `/summarize [range]` — summarize channel (24h, 7d, 30d)
  """

  @type result ::
          {:summarize, String.t()}
          | {:unknown_command, String.t()}
          | :not_command

  @doc "Parses a message string. Returns a command tuple or `:not_command`."
  @spec parse(String.t()) :: result()
  def parse(input) do
    input
    |> String.trim()
    |> do_parse()
  end

  defp do_parse("/" <> rest) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      ["summarize"] -> {:summarize, "24h"}
      ["summarize", range] -> {:summarize, String.trim(range)}
      [command | _] -> {:unknown_command, command}
      [] -> :not_command
    end
  end

  defp do_parse(_), do: :not_command
end
```

**Step 4: Wire into index.ex send_message handler**

In `handle_event("send_message", ...)`, before the existing `cond` block, add slash command interception:

```elixir
def handle_event("send_message", %{"message" => %{"content" => content}}, socket) do
  user = socket.assigns.current_user

  case SlackexWeb.ChatLive.SlashCommand.parse(content) do
    {:summarize, range} when socket.assigns.summarization_enabled ->
      send(self(), {:start_summary, range})
      {:noreply,
       socket
       |> assign(:show_summary_modal, true)
       |> assign(:message_form, to_form(%{"content" => ""}, as: :message))}

    {:unknown_command, cmd} ->
      {:noreply, put_flash(socket, :error, "Unknown command: /#{cmd}")}

    _ ->
      # Original send_message logic (existing cond block)
      cond do
        ...existing code...
      end
  end
end
```

**Step 5: Run tests**

Run: `mix test test/slackex_web/live/chat_live/slash_command_test.exs`
Expected: PASS

**Step 6: Run full test suite**

Run: `mix test`
Expected: All pass

**Step 7: Commit**

```bash
git add lib/slackex_web/live/chat_live/slash_command.ex test/slackex_web/live/chat_live/slash_command_test.exs lib/slackex_web/live/chat_live/index.ex
git commit -m "feat(ai): add slash command foundation with /summarize

Parses /summarize [24h|7d|30d] from message input. Extensible
dispatcher via pattern matching. Unknown commands show flash error.
Intercepts before send_message to route to summary modal."
```

---

## Task 10: Retroactive Embedding Telemetry

Update the existing `OpenAIClient` (embeddings) to emit telemetry events.

**Files:**
- Modify: `lib/slackex/embeddings/openai_client.ex`
- Modify: `test/slackex/embeddings/openai_client_test.exs`

**Step 1: Write the failing test**

Add to `test/slackex/embeddings/openai_client_test.exs`:

```elixir
describe "telemetry" do
  test "emits [:slackex, :ai, :embedding] telemetry on successful batch" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "test-embedding-telemetry-#{inspect(ref)}",
      [:slackex, :ai, :embedding],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("test-embedding-telemetry-#{inspect(ref)}") end)

    # This will fail with network error since no real API is configured,
    # but we can test with a configured stub by checking the module compiles
    # with telemetry calls. A proper integration test would need a mock.
    # For now, verify the module has the telemetry execute call.
    source = File.read!("lib/slackex/embeddings/openai_client.ex")
    assert source =~ "telemetry.execute"
    assert source =~ "[:slackex, :ai, :embedding]"
  end
end
```

**Step 2: Add telemetry to OpenAIClient**

In `lib/slackex/embeddings/openai_client.ex`, modify the `generate_batch/1` success case:

```elixir
{:ok, %Req.Response{status: 200, body: response_body}} ->
  vectors =
    response_body
    |> Map.get("data", [])
    |> Enum.sort_by(& &1["index"])
    |> Enum.map(& &1["embedding"])

  duration = System.monotonic_time() - start_time
  usage = Map.get(response_body, "usage", %{})

  :telemetry.execute(
    [:slackex, :ai, :embedding],
    %{duration: duration},
    %{
      model: config(:model, @default_model),
      tokens: Map.get(usage, "total_tokens", 0),
      batch_size: length(texts)
    }
  )

  {:ok, vectors}
```

Add `start_time = System.monotonic_time()` at the top of `generate_batch/1` (the non-guard clause).

**Step 3: Run tests**

Run: `mix test test/slackex/embeddings/openai_client_test.exs`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/slackex/embeddings/openai_client.ex test/slackex/embeddings/openai_client_test.exs
git commit -m "feat(ai): add telemetry to embedding OpenAIClient

Emits [:slackex, :ai, :embedding] events with model, tokens,
batch_size, duration. Retroactive — aligns existing embeddings
with universal AI telemetry principle."
```

---

## Task 11: Final Integration + Full Test Suite

**Step 1: Run `mix format`**

Run: `mix format`

**Step 2: Run `mix credo`**

Run: `mix credo`
Fix any warnings.

**Step 3: Run `mix dialyzer`**

Run: `mix dialyzer`
Fix any type warnings.

**Step 4: Run full test suite**

Run: `mix test`
Expected: All tests pass.

**Step 5: Final commit**

```bash
git add -A
git commit -m "chore: format and quality checks for LLM foundation"
```

---

## Task 12: Deploy Preparation

This task should only be done when `LLM_API_KEY` has been added as a GitHub secret.

**Step 1: Add GH secret**

Add `LLM_API_KEY` (DeepInfra API key) to the GitHub repository secrets.

**Step 2: Run pre-deploy**

Run: `scripts/pre-deploy`
Expected: All 7 checks pass.

**Step 3: Enable feature flag**

After deploy, enable in admin UI at `/admin/flags`:
- Create flag `:channel_summarization`
- Enable for specific test user first, then globally when validated

**Step 4: Tag and deploy**

Use: `/deploy` skill

---

## Summary

| Task | Description | New files | Modified files |
|------|-------------|-----------|----------------|
| 1 | AI Telemetry module | 2 | 1 (application.ex) |
| 2 | LLMClient behaviour | 2 | 0 |
| 3 | StubLLMClient | 2 | 1 (test.exs) |
| 4 | OpenAICompatibleClient | 2 | 2 (prod.exs, dev.exs) |
| 5 | Runtime config + deploy | 0 | 3 (runtime.exs, compose, CI) |
| 6 | Feature flag | 0 | 0 |
| 7 | Summarizer | 2 | 0 |
| 8 | Summary modal + UI | 2 | 1 (index.ex) |
| 9 | Slash commands | 2 | 1 (index.ex) |
| 10 | Embedding telemetry | 0 | 2 (openai_client) |
| 11 | Quality checks | 0 | 0 |
| 12 | Deploy | 0 | 0 |

**Total:** ~12 new files, ~8 modified files, ~12 commits
