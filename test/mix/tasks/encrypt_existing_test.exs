defmodule Mix.Tasks.Slackex.EncryptExistingTest do
  use Slackex.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Slackex.EncryptExisting
  alias Slackex.Accounts.User
  alias Slackex.Chat.{AbuseReport, DMRequest, Message}
  alias Slackex.Repo

  # ---------------------------------------------------------------------------
  # Setup: re-add plaintext columns that the drop migration removed.
  # Uses a raw Postgrex connection to bypass the Ecto sandbox so DDL
  # changes persist across sandbox transaction boundaries.
  # ---------------------------------------------------------------------------

  @ddl_add [
    "ALTER TABLE messages ADD COLUMN IF NOT EXISTS content text",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS email varchar(255)",
    "ALTER TABLE dm_requests ADD COLUMN IF NOT EXISTS preview_text varchar(255)",
    "ALTER TABLE abuse_reports ADD COLUMN IF NOT EXISTS description varchar(255)",
    "ALTER TABLE abuse_reports ADD COLUMN IF NOT EXISTS metadata jsonb"
  ]

  @ddl_drop [
    "ALTER TABLE messages DROP COLUMN IF EXISTS content",
    "ALTER TABLE users DROP COLUMN IF EXISTS email",
    "ALTER TABLE dm_requests DROP COLUMN IF EXISTS preview_text",
    "ALTER TABLE abuse_reports DROP COLUMN IF EXISTS description",
    "ALTER TABLE abuse_reports DROP COLUMN IF EXISTS metadata"
  ]

  defp run_ddl(statements) do
    config = Repo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port],
        username: config[:username],
        password: config[:password],
        database: config[:database]
      )

    Enum.each(statements, fn sql ->
      Postgrex.query!(conn, sql, [])
    end)

    GenServer.stop(conn)
  end

  setup_all do
    run_ddl(@ddl_add)

    on_exit(fn ->
      run_ddl(@ddl_drop)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers -- insert legacy plaintext rows via raw SQL so the Ecto schemas
  # (which now point at encrypted_* columns) are bypassed.
  # ---------------------------------------------------------------------------

  defp insert_plaintext_message(channel_id, sender_id, content) do
    id = System.unique_integer([:positive]) + 1_000_000_000_000

    inserted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      """
      INSERT INTO messages (id, content, channel_id, sender_id, inserted_at)
      VALUES ($1, $2, $3, $4, $5)
      """,
      [id, content, channel_id, sender_id, inserted_at]
    )

    id
  end

  defp insert_plaintext_user(username, email) do
    hashed_password = Bcrypt.hash_pwd_salt("password123")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO users (username, email, hashed_password, status, dm_preference, inserted_at, updated_at)
        VALUES ($1, $2, $3, 'offline', 'anyone', $4, $4)
        RETURNING id
        """,
        [username, email, hashed_password, now]
      )

    id
  end

  defp insert_plaintext_dm_request(sender_id, recipient_id, preview_text) do
    id = System.unique_integer([:positive]) + 1_000_000_000_000
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      """
      INSERT INTO dm_requests (id, sender_id, recipient_id, preview_text, status, inserted_at)
      VALUES ($1, $2, $3, $4, 'pending', $5)
      """,
      [id, sender_id, recipient_id, preview_text, now]
    )

    id
  end

  defp insert_plaintext_abuse_report(reporter_id, reported_user_id, description, metadata) do
    id = System.unique_integer([:positive]) + 1_000_000_000_000
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      """
      INSERT INTO abuse_reports (id, reporter_id, reported_user_id, category, description, metadata, status, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'spam', $4, $5, 'open', $6, $6)
      """,
      [id, reporter_id, reported_user_id, description, metadata, now]
    )

    id
  end

  defp get_raw_row(table, id) do
    %{rows: [row], columns: columns} =
      Repo.query!("SELECT * FROM #{table} WHERE id = $1", [id])

    Enum.zip(columns, row) |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "mix slackex.encrypt_existing" do
    test "encrypts all plaintext message content" do
      channel = insert(:channel)
      user = insert(:user)

      msg_id = insert_plaintext_message(channel.id, user.id, "Hello plaintext world")

      # Verify plaintext is set and encrypted is null before migration
      raw_before = get_raw_row("messages", msg_id)
      assert raw_before["content"] == "Hello plaintext world"
      assert raw_before["encrypted_content"] == nil

      capture_io(fn ->
        EncryptExisting.run([])
      end)

      # After migration: encrypted column populated
      raw_after = get_raw_row("messages", msg_id)
      assert raw_after["encrypted_content"] != nil

      # Readable through normal Ecto schema
      message = Repo.get!(Message, msg_id)
      assert message.content == "Hello plaintext world"
    end

    test "encrypts all plaintext user emails and populates email_hash" do
      user_id = insert_plaintext_user("legacy_user", "legacy@example.com")

      raw_before = get_raw_row("users", user_id)
      assert raw_before["email"] == "legacy@example.com"
      assert raw_before["encrypted_email"] == nil
      assert raw_before["email_hash"] == nil

      capture_io(fn ->
        EncryptExisting.run([])
      end)

      raw_after = get_raw_row("users", user_id)
      assert raw_after["encrypted_email"] != nil
      assert raw_after["email_hash"] != nil

      # Readable through normal Ecto schema
      user = Repo.get!(User, user_id)
      assert user.email == "legacy@example.com"
    end

    test "encrypts all plaintext dm_request preview_text" do
      sender = insert(:user)
      recipient = insert(:user)

      dm_id = insert_plaintext_dm_request(sender.id, recipient.id, "Hey, can we talk?")

      raw_before = get_raw_row("dm_requests", dm_id)
      assert raw_before["preview_text"] == "Hey, can we talk?"
      assert raw_before["encrypted_preview_text"] == nil

      capture_io(fn ->
        EncryptExisting.run([])
      end)

      raw_after = get_raw_row("dm_requests", dm_id)
      assert raw_after["encrypted_preview_text"] != nil

      dm_request = Repo.get!(DMRequest, dm_id)
      assert dm_request.preview_text == "Hey, can we talk?"
    end

    test "encrypts all plaintext abuse_report description and metadata" do
      reporter = insert(:user)
      reported = insert(:user)
      metadata_json = Jason.encode!(%{"evidence" => "screenshot.png"})

      report_id =
        insert_plaintext_abuse_report(
          reporter.id,
          reported.id,
          "Spamming links",
          metadata_json
        )

      raw_before = get_raw_row("abuse_reports", report_id)
      assert raw_before["description"] == "Spamming links"
      assert raw_before["encrypted_description"] == nil
      assert raw_before["encrypted_metadata"] == nil

      capture_io(fn ->
        EncryptExisting.run([])
      end)

      raw_after = get_raw_row("abuse_reports", report_id)
      assert raw_after["encrypted_description"] != nil
      assert raw_after["encrypted_metadata"] != nil

      report = Repo.get!(AbuseReport, report_id)
      assert report.description == "Spamming links"
      assert report.metadata == %{"evidence" => "screenshot.png"}
    end

    test "processes rows in batches and logs progress" do
      channel = insert(:channel)
      user = insert(:user)

      # Insert 3 plaintext messages to confirm batch logging
      for i <- 1..3 do
        insert_plaintext_message(channel.id, user.id, "Batch message #{i}")
      end

      log =
        capture_io(fn ->
          EncryptExisting.run([])
        end)

      # Verify progress logging mentions row counts
      assert log =~ "messages"
      assert log =~ "3"
    end

    test "skips rows that are already encrypted" do
      # Insert a message through the normal schema (already encrypted)
      channel = insert(:channel)
      user = insert(:user)
      message = insert(:message, channel: channel, sender: user)

      # Also insert a plaintext row
      plain_id = insert_plaintext_message(channel.id, user.id, "Needs encryption")

      capture_io(fn ->
        EncryptExisting.run([])
      end)

      # The already-encrypted message should remain unchanged
      reloaded = Repo.get!(Message, message.id)
      assert reloaded.content == message.content

      # The plaintext row should now be encrypted
      raw_after = get_raw_row("messages", plain_id)
      assert raw_after["encrypted_content"] != nil
    end
  end
end
