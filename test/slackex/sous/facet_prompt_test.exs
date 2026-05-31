defmodule Slackex.Sous.FacetPromptTest do
  use ExUnit.Case, async: true

  alias Slackex.Sous.{Decision, FacetPrompt, Viewer, WorkItem}

  defp viewer do
    %Viewer{
      id: "cto",
      name: "CTO",
      color: "#7c5cff",
      focus: ["shipping", "risks", "decisions"]
    }
  end

  defp work_item do
    %WorkItem{
      id: 123,
      kind: :decision,
      state: :mise,
      title: "Bridge",
      people: %{},
      channel_id: 1
    }
  end

  defp decision do
    %Decision{
      work_item_id: 123,
      what: "Adopt FooBar in service X",
      why: "Reduces latency",
      next: "Spike for one week"
    }
  end

  test "build/3 returns a system and user message" do
    messages = FacetPrompt.build(viewer(), work_item(), decision())

    assert [%{role: "system", content: _}, %{role: "user", content: _}] = messages
  end

  test "user message contains viewer name, focus areas, and all four decision fields" do
    [_system, %{content: user_content}] = FacetPrompt.build(viewer(), work_item(), decision())

    assert user_content =~ "CTO"
    assert user_content =~ "shipping, risks, decisions"
    assert user_content =~ "Adopt FooBar in service X"
    assert user_content =~ "Reduces latency"
    assert user_content =~ "Spike for one week"
    assert user_content =~ "Bridge"
    assert user_content =~ "mise"
  end

  test "build/3 is deterministic — same inputs produce identical output" do
    a = FacetPrompt.build(viewer(), work_item(), decision())
    b = FacetPrompt.build(viewer(), work_item(), decision())
    assert a == b
  end

  test "prompt_version/0 returns 2" do
    assert FacetPrompt.prompt_version() == 2
  end
end
