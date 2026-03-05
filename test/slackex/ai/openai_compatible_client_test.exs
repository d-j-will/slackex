defmodule Slackex.AI.OpenAICompatibleClientTest do
  use ExUnit.Case, async: false

  alias Slackex.AI.OpenAICompatibleClient

  setup do
    original = Application.get_env(:slackex, :llm_api)

    on_exit(fn ->
      if original,
        do: Application.put_env(:slackex, :llm_api, original),
        else: Application.delete_env(:slackex, :llm_api)
    end)

    :ok
  end

  describe "complete/2" do
    test "returns :not_configured when no API key" do
      Application.delete_env(:slackex, :llm_api)

      assert {:error, :not_configured} =
               OpenAICompatibleClient.complete(
                 [%{role: "user", content: "test"}],
                 []
               )
    end

    test "attempts API call when configured (network error expected)" do
      Application.put_env(:slackex, :llm_api, %{
        api_url: "http://localhost:1",
        model: "test-model",
        api_key: "test-key",
        max_tokens: 512,
        temperature: 0.5
      })

      assert {:error, {:network_error, _}} =
               OpenAICompatibleClient.complete(
                 [%{role: "user", content: "test"}],
                 []
               )
    end
  end

  describe "stream/2" do
    test "returns :not_configured when no API key" do
      Application.delete_env(:slackex, :llm_api)

      assert {:error, :not_configured} =
               OpenAICompatibleClient.stream(
                 [%{role: "user", content: "test"}],
                 []
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
