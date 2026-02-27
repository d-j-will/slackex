defmodule Slackex.Chat.DMRequestTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat.DMRequest

  describe "changeset/2 validations" do
    test "valid attrs produce a valid changeset" do
      sender = insert(:user)
      recipient = insert(:user)

      changeset =
        DMRequest.changeset(%DMRequest{}, %{
          sender_id: sender.id,
          recipient_id: recipient.id,
          preview_text: "Hey, want to chat?"
        })

      assert changeset.valid?
    end

    test "sender_id and recipient_id are required" do
      changeset = DMRequest.changeset(%DMRequest{}, %{})

      refute changeset.valid?

      assert %{sender_id: ["can't be blank"], recipient_id: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "preview_text over 500 chars is rejected" do
      sender = insert(:user)
      recipient = insert(:user)
      long_text = String.duplicate("a", 501)

      changeset =
        DMRequest.changeset(%DMRequest{}, %{
          sender_id: sender.id,
          recipient_id: recipient.id,
          preview_text: long_text
        })

      refute changeset.valid?
      assert %{preview_text: ["should be at most 500 character(s)"]} = errors_on(changeset)
    end

    test "preview_text at exactly 500 chars is accepted" do
      sender = insert(:user)
      recipient = insert(:user)

      changeset =
        DMRequest.changeset(%DMRequest{}, %{
          sender_id: sender.id,
          recipient_id: recipient.id,
          preview_text: String.duplicate("a", 500)
        })

      assert changeset.valid?
    end

    test "status must be pending, accepted, or declined" do
      sender = insert(:user)
      recipient = insert(:user)

      changeset =
        DMRequest.changeset(%DMRequest{}, %{
          sender_id: sender.id,
          recipient_id: recipient.id,
          status: "invalid"
        })

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "status defaults to pending" do
      sender = insert(:user)
      recipient = insert(:user)

      changeset =
        DMRequest.changeset(%DMRequest{}, %{
          sender_id: sender.id,
          recipient_id: recipient.id
        })

      assert changeset.valid?
      assert get_field(changeset, :status) == "pending"
    end
  end

  describe "database roundtrip" do
    test "inserting a valid dm_request succeeds with Snowflake ID" do
      sender = insert(:user)
      recipient = insert(:user)

      id = Slackex.Infrastructure.Snowflake.generate()

      assert {:ok, dm_request} =
               %DMRequest{id: id}
               |> DMRequest.changeset(%{
                 sender_id: sender.id,
                 recipient_id: recipient.id,
                 preview_text: "Hello!"
               })
               |> Repo.insert()

      assert dm_request.id == id
      assert dm_request.sender_id == sender.id
      assert dm_request.recipient_id == recipient.id
      assert dm_request.preview_text == "Hello!"
      assert dm_request.status == "pending"
      assert dm_request.inserted_at
      assert dm_request.responded_at == nil
      assert dm_request.dm_conversation_id == nil
    end

    test "belongs_to associations are defined" do
      sender = insert(:user)
      recipient = insert(:user)

      id = Slackex.Infrastructure.Snowflake.generate()

      {:ok, dm_request} =
        %DMRequest{id: id}
        |> DMRequest.changeset(%{
          sender_id: sender.id,
          recipient_id: recipient.id
        })
        |> Repo.insert()

      dm_request = Repo.preload(dm_request, [:sender, :recipient])

      assert dm_request.sender.id == sender.id
      assert dm_request.recipient.id == recipient.id
    end

    test "dm_conversation association is optional" do
      sender = insert(:user)
      recipient = insert(:user)
      dm = insert(:dm_conversation)

      id = Slackex.Infrastructure.Snowflake.generate()

      {:ok, dm_request} =
        %DMRequest{id: id}
        |> DMRequest.changeset(%{
          sender_id: sender.id,
          recipient_id: recipient.id,
          dm_conversation_id: dm.id
        })
        |> Repo.insert()

      dm_request = Repo.preload(dm_request, :dm_conversation)
      assert dm_request.dm_conversation_id == dm.id
      assert dm_request.dm_conversation.id == dm.id
    end

    test "unique partial index prevents duplicate pending requests" do
      sender = insert(:user)
      recipient = insert(:user)

      id1 = Slackex.Infrastructure.Snowflake.generate()
      id2 = Slackex.Infrastructure.Snowflake.generate()

      {:ok, _} =
        %DMRequest{id: id1}
        |> DMRequest.changeset(%{
          sender_id: sender.id,
          recipient_id: recipient.id
        })
        |> Repo.insert()

      assert {:error, changeset} =
               %DMRequest{id: id2}
               |> DMRequest.changeset(%{
                 sender_id: sender.id,
                 recipient_id: recipient.id
               })
               |> Repo.insert()

      assert %{sender_id: ["already has a pending request to this user"]} =
               errors_on(changeset)
    end

    test "accepted request allows a new pending request for same pair" do
      sender = insert(:user)
      recipient = insert(:user)

      id1 = Slackex.Infrastructure.Snowflake.generate()
      id2 = Slackex.Infrastructure.Snowflake.generate()

      {:ok, first_request} =
        %DMRequest{id: id1}
        |> DMRequest.changeset(%{
          sender_id: sender.id,
          recipient_id: recipient.id
        })
        |> Repo.insert()

      # Mark first request as accepted
      first_request
      |> DMRequest.changeset(%{status: "accepted"})
      |> Repo.update!()

      # A new pending request should now be allowed
      assert {:ok, _} =
               %DMRequest{id: id2}
               |> DMRequest.changeset(%{
                 sender_id: sender.id,
                 recipient_id: recipient.id
               })
               |> Repo.insert()
    end
  end
end
