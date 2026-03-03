defmodule Slackex.Embeddings.PersistenceListenerTest do
  use Slackex.DataCase, async: false

  alias Slackex.Embeddings.PersistenceListener

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_channel_message(channel, sender, content) do
    msg = insert(:message, channel: channel, sender: sender, content: content)

    {1, _} =
      from(m in Slackex.Chat.Message, where: m.id == ^msg.id)
      |> Repo.update_all(set: [search_content: content])

    Repo.get!(Slackex.Chat.Message, msg.id)
  end

  # ---------------------------------------------------------------------------
  # Acceptance: PubSub event triggers EmbeddingWorker enqueue
  # ---------------------------------------------------------------------------

  describe "PersistenceListener subscribes and enqueues" do
    test "enqueues EmbeddingWorker jobs when {:messages_persisted, message_ids} is broadcast" do
      channel = insert(:channel)
      sender = insert(:user)
      msg1 = insert_channel_message(channel, sender, "Hello listener")
      msg2 = insert_channel_message(channel, sender, "Goodbye listener")

      # The listener is already running from the application supervisor,
      # subscribed to "pipeline:events". Broadcast the event directly.
      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        "pipeline:events",
        {:messages_persisted, [msg1.id, msg2.id]}
      )

      # Give the GenServer time to handle the message.
      # In inline Oban mode, jobs execute synchronously on insert.
      Process.sleep(100)

      # With Oban inline testing, the worker runs immediately.
      # Verify embeddings were created (proving the worker was enqueued and ran).
      emb1 = Repo.get(Slackex.Embeddings.MessageEmbedding, msg1.id)
      emb2 = Repo.get(Slackex.Embeddings.MessageEmbedding, msg2.id)

      assert emb1 != nil, "Expected embedding for message #{msg1.id}"
      assert emb2 != nil, "Expected embedding for message #{msg2.id}"
    end

    test "ignores unrelated PubSub messages without crashing" do
      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        "pipeline:events",
        {:some_other_event, %{data: "irrelevant"}}
      )

      # Give the GenServer time to process
      Process.sleep(50)

      # Listener should still be alive
      assert Process.whereis(PersistenceListener) != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: PersistenceListener is supervised and running
  # ---------------------------------------------------------------------------

  describe "supervision" do
    test "is running and registered under its module name from the application supervisor" do
      assert Process.whereis(PersistenceListener) != nil
    end
  end
end
