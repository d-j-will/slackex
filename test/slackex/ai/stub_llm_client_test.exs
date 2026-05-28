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
      assert [_ | _] = chunks
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

  describe "complete/2 with opts[:purpose] = :sous_facet (B2 branch)" do
    alias Slackex.Sous.{Decision, FacetPrompt, Viewer, WorkItem}

    defp build_facet_messages do
      viewer = %Viewer{
        id: "cto",
        name: "CTO",
        color: "#7c5cff",
        focus: ["shipping", "risks", "decisions"]
      }

      work_item = %WorkItem{id: 1, kind: :decision, state: :mise, title: "Bridge", people: %{}}

      decision = %Decision{
        work_item_id: 1,
        what: "Adopt FooBar",
        why: "Latency",
        next: "Spike"
      }

      FacetPrompt.build(viewer, work_item, decision)
    end

    test "returns viewer-distinguishable, deterministic facet text" do
      messages = build_facet_messages()
      {:ok, text} = StubLLMClient.complete(messages, purpose: :sous_facet)

      assert text =~ "[stub:CTO]"
      assert text =~ "Adopt FooBar"
      assert text =~ "shipping, risks, decisions"
    end

    test "same input -> identical output (CI determinism guarantee)" do
      messages = build_facet_messages()
      {:ok, a} = StubLLMClient.complete(messages, purpose: :sous_facet)
      {:ok, b} = StubLLMClient.complete(messages, purpose: :sous_facet)
      assert a == b
    end

    test "no purpose opt -> unchanged canned-summary behaviour" do
      messages = [%{role: "user", content: "Anything"}]
      {:ok, text} = StubLLMClient.complete(messages, [])
      assert text =~ "Here is a summary"
    end
  end
end
