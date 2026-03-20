defmodule Slackex.AI.SummarizerTest do
  use Slackex.DataCase, async: false

  alias Slackex.AI.Summarizer

  describe "summarize_channel/4" do
    test "returns error when no messages in range" do
      Application.put_env(:slackex, :llm_api, %{api_key: "stub"})
      on_exit(fn -> Application.delete_env(:slackex, :llm_api) end)

      channel = insert(:channel)
      user = insert(:user)
      since = DateTime.utc_now()

      assert {:error, :no_messages} =
               Summarizer.summarize_channel(channel.id, since, user.id, [])
    end

    test "returns error when LLM not configured" do
      original_client = Application.get_env(:slackex, :llm_client)
      original_api = Application.get_env(:slackex, :llm_api)
      Application.delete_env(:slackex, :llm_client)
      Application.delete_env(:slackex, :llm_api)

      on_exit(fn ->
        if original_client,
          do: Application.put_env(:slackex, :llm_client, original_client),
          else: Application.delete_env(:slackex, :llm_client)

        if original_api,
          do: Application.put_env(:slackex, :llm_api, original_api),
          else: Application.delete_env(:slackex, :llm_api)
      end)

      channel = insert(:channel)
      user = insert(:user)
      since = DateTime.add(DateTime.utc_now(), -86_400, :second)

      assert {:error, :not_configured} =
               Summarizer.summarize_channel(channel.id, since, user.id, [])
    end

    test "streams a summary for channel messages" do
      # StubLLMClient is configured in test — set :llm_api so configured?() returns true
      Application.put_env(:slackex, :llm_api, %{api_key: "stub"})
      on_exit(fn -> Application.delete_env(:slackex, :llm_api) end)

      channel = insert(:channel)
      sender = insert(:user)
      user = insert(:user)

      insert_channel_message(channel, sender, "We should deploy the new feature")
      insert_channel_message(channel, sender, "Agreed, let's ship it tomorrow")

      since = DateTime.add(DateTime.utc_now(), -86_400, :second)

      assert {:ok, stream} = Summarizer.summarize_channel(channel.id, since, user.id, [])
      chunks = Enum.to_list(stream)
      assert [_ | _] = chunks
      full_text = Enum.join(chunks)
      assert String.length(full_text) > 0
    end
  end

  describe "summarize_dm/4" do
    test "returns error when no DM messages in range" do
      Application.put_env(:slackex, :llm_api, %{api_key: "stub"})
      on_exit(fn -> Application.delete_env(:slackex, :llm_api) end)

      dm = insert(:dm_conversation)
      user = insert(:user)
      since = DateTime.utc_now()

      assert {:error, :no_messages} =
               Summarizer.summarize_dm(dm.id, since, user.id, [])
    end

    test "streams a summary for DM messages" do
      Application.put_env(:slackex, :llm_api, %{api_key: "stub"})
      on_exit(fn -> Application.delete_env(:slackex, :llm_api) end)

      dm = insert(:dm_conversation)

      insert_dm_message(dm, dm.user_a, "Hey, can you review my PR?")
      insert_dm_message(dm, dm.user_b, "Sure, I'll look at it this afternoon")

      since = DateTime.add(DateTime.utc_now(), -86_400, :second)

      assert {:ok, stream} = Summarizer.summarize_dm(dm.id, since, dm.user_a.id, [])
      chunks = Enum.to_list(stream)
      assert [_ | _] = chunks
      full_text = Enum.join(chunks)
      assert String.length(full_text) > 0
    end
  end

  describe "build_dm_prompt/2" do
    test "includes time range in DM prompt" do
      {system, user_msg} = Summarizer.build_dm_prompt("Monday", "Some context here")
      assert system =~ "direct message"
      assert user_msg =~ "Monday"
      assert user_msg =~ "Some context here"
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
