defmodule Slackex.ReleaseTest do
  @moduledoc false

  use Slackex.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Slackex.Chat.Message
  alias Slackex.Release

  describe "decode_html_entities/0" do
    setup do
      channel = insert(:channel)
      sender = insert(:user)

      # Logger level is :warning in test config; temporarily raise to :info
      # so we can capture the Release module's info-level progress messages.
      previous_level = Logger.level()
      Logger.configure(level: :info)

      on_exit(fn ->
        Logger.configure(level: previous_level)
      end)

      %{channel: channel, sender: sender}
    end

    test "decodes HTML entities in content and search_content", %{
      channel: channel,
      sender: sender
    } do
      # Insert a message simulating pre-v0.5.82 data where strip_tags encoded entities
      encoded_content =
        "Hello &amp; welcome &gt; enjoy &lt;this&gt; &quot;great&quot; it&#39;s fun"

      expected_content = "Hello & welcome > enjoy <this> \"great\" it's fun"

      msg = insert(:message, channel: channel, sender: sender, content: encoded_content)

      # ExMachina bypasses changesets, so search_content isn't set.
      # Set it directly to simulate the encoded state.
      {1, _} =
        from(m in Message, where: m.id == ^msg.id)
        |> Repo.update_all(set: [search_content: encoded_content])

      # Verify pre-condition: search_content has entities
      before = Repo.get!(Message, msg.id)
      assert before.search_content == encoded_content

      capture_log(fn ->
        Release.decode_html_entities()
      end)

      # Verify both fields are decoded
      after_msg = Repo.get!(Message, msg.id)
      assert after_msg.content == expected_content
      assert after_msg.search_content == expected_content
    end

    test "is idempotent — already clean messages are not modified", %{
      channel: channel,
      sender: sender
    } do
      # Insert a message with clean content (no HTML entities)
      clean_content = "Hello world, no entities here"
      msg = insert(:message, channel: channel, sender: sender, content: clean_content)

      {1, _} =
        from(m in Message, where: m.id == ^msg.id)
        |> Repo.update_all(set: [search_content: clean_content])

      log =
        capture_log(fn ->
          Release.decode_html_entities()
        end)

      # Clean messages should not be processed
      assert log =~ "Found 0 messages with HTML entities"

      after_msg = Repo.get!(Message, msg.id)
      assert after_msg.content == clean_content
      assert after_msg.search_content == clean_content
    end

    test "handles messages with only some entity types", %{channel: channel, sender: sender} do
      # Message with only &gt; entities
      encoded = "quote &gt; text"
      expected = "quote > text"

      msg = insert(:message, channel: channel, sender: sender, content: encoded)

      {1, _} =
        from(m in Message, where: m.id == ^msg.id)
        |> Repo.update_all(set: [search_content: encoded])

      capture_log(fn ->
        Release.decode_html_entities()
      end)

      after_msg = Repo.get!(Message, msg.id)
      assert after_msg.content == expected
      assert after_msg.search_content == expected
    end

    test "preserves double-encoded entities from user-typed literal &gt;", %{
      channel: channel,
      sender: sender
    } do
      # User typed literal "&gt;" which strip_tags encoded to "&amp;gt;"
      # After decoding, it should become "&gt;" (the user's original text)
      encoded = "literal &amp;gt; entity"
      expected = "literal &gt; entity"

      msg = insert(:message, channel: channel, sender: sender, content: encoded)

      {1, _} =
        from(m in Message, where: m.id == ^msg.id)
        |> Repo.update_all(set: [search_content: encoded])

      capture_log(fn ->
        Release.decode_html_entities()
      end)

      after_msg = Repo.get!(Message, msg.id)
      assert after_msg.content == expected
      assert after_msg.search_content == expected
    end

    test "skips deleted messages", %{channel: channel, sender: sender} do
      encoded = "deleted &gt; message"

      msg = insert(:message, channel: channel, sender: sender, content: encoded)

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {1, _} =
        from(m in Message, where: m.id == ^msg.id)
        |> Repo.update_all(set: [search_content: encoded, deleted_at: now])

      log =
        capture_log(fn ->
          Release.decode_html_entities()
        end)

      assert log =~ "Found 0 messages with HTML entities"

      after_msg = Repo.get!(Message, msg.id)
      # Content still encoded because deleted messages are skipped
      assert after_msg.search_content == encoded
    end

    test "logs sampling checkpoint and progress", %{channel: channel, sender: sender} do
      encoded = "test &gt; logging"
      msg = insert(:message, channel: channel, sender: sender, content: encoded)

      {1, _} =
        from(m in Message, where: m.id == ^msg.id)
        |> Repo.update_all(set: [search_content: encoded])

      log =
        capture_log(fn ->
          Release.decode_html_entities()
        end)

      assert log =~ "[DecodeEntities] Found 1 messages with HTML entities"
      assert log =~ "Sampling checkpoint:"
      assert log =~ "verified successfully"
      assert log =~ "[DecodeEntities] Done"
    end
  end
end
