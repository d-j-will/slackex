defmodule Slackex.VaultKeyRotationTest do
  use Slackex.DataCase, async: false

  import ExUnit.CaptureIO

  alias Slackex.Repo

  @original_key Base.decode64!("AlhhcUBFZI1809fnVZuYlpT8GxESMBZ7XgtmRo16PA8=")
  @new_key :crypto.strong_rand_bytes(32)

  @original_vault_config [
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: @original_key}
    ]
  ]

  setup do
    on_exit(fn ->
      # Restore original vault config after each test
      Slackex.Vault.reconfigure(@original_vault_config)
    end)

    :ok
  end

  describe "key rotation acceptance" do
    test "data encrypted with original key is readable after adding new primary key" do
      # Insert data with the original key (current config)
      message = insert(:message, content: "secret under original key")
      user = insert(:user, email: "rotation@example.com")

      # Verify data is readable with original key
      assert Repo.get!(Slackex.Chat.Message, message.id).content == "secret under original key"
      assert Repo.get!(Slackex.Accounts.User, user.id).email == "rotation@example.com"

      # Reconfigure Vault with new primary key + retired original key
      Slackex.Vault.reconfigure(dual_key_config())

      # Data encrypted with original key is still readable
      assert Repo.get!(Slackex.Chat.Message, message.id).content == "secret under original key"
      assert Repo.get!(Slackex.Accounts.User, user.id).email == "rotation@example.com"
    end

    test "new data is encrypted with new primary key, not the retired key" do
      # Insert data with original key first
      old_message = insert(:message, content: "old key data")
      old_ciphertext = get_raw_encrypted("messages", "encrypted_content", old_message.id)

      # Switch to new primary key
      Slackex.Vault.reconfigure(dual_key_config())

      # Insert new data -- should use new primary key
      new_message = insert(:message, content: "new key data")
      new_ciphertext = get_raw_encrypted("messages", "encrypted_content", new_message.id)

      # Both should be readable
      assert Repo.get!(Slackex.Chat.Message, old_message.id).content == "old key data"
      assert Repo.get!(Slackex.Chat.Message, new_message.id).content == "new key data"

      # Ciphertexts should differ (different cipher tags mean different binary prefixes)
      assert old_ciphertext != new_ciphertext
    end

    test "mix slackex.rotate_key re-encrypts all rows with current primary key" do
      # Insert data with original key across all encrypted schemas
      message = insert(:message, content: "rotate me message")
      user = insert(:user, email: "rotate@example.com")
      dm_request = insert(:dm_request, preview_text: "rotate me preview")

      abuse_report =
        insert_abuse_report("rotate me description", %{"evidence" => "screenshot.png"})

      # Capture original ciphertexts
      original_msg_ct = get_raw_encrypted("messages", "encrypted_content", message.id)
      original_user_ct = get_raw_encrypted("users", "encrypted_email", user.id)
      original_dm_ct = get_raw_encrypted("dm_requests", "encrypted_preview_text", dm_request.id)

      original_report_ct =
        get_raw_encrypted("abuse_reports", "encrypted_description", abuse_report.id)

      # Switch to new primary key with retired old key
      Slackex.Vault.reconfigure(dual_key_config())

      # Run key rotation task
      capture_io(fn ->
        Mix.Tasks.Slackex.RotateKey.run([])
      end)

      # All data should still be readable
      assert Repo.get!(Slackex.Chat.Message, message.id).content == "rotate me message"
      assert Repo.get!(Slackex.Accounts.User, user.id).email == "rotate@example.com"

      assert Repo.get!(Slackex.Chat.DMRequest, dm_request.id).preview_text ==
               "rotate me preview"

      report = Repo.get!(Slackex.Chat.AbuseReport, abuse_report.id)
      assert report.description == "rotate me description"
      assert report.metadata == %{"evidence" => "screenshot.png"}

      # Ciphertexts should have changed (re-encrypted with new key)
      assert get_raw_encrypted("messages", "encrypted_content", message.id) != original_msg_ct
      assert get_raw_encrypted("users", "encrypted_email", user.id) != original_user_ct

      assert get_raw_encrypted("dm_requests", "encrypted_preview_text", dm_request.id) !=
               original_dm_ct

      assert get_raw_encrypted("abuse_reports", "encrypted_description", abuse_report.id) !=
               original_report_ct
    end

    test "after rotation, data is readable using only the new primary key" do
      # Insert data with original key
      message = insert(:message, content: "will survive rotation")

      # Switch to new primary + retired old
      Slackex.Vault.reconfigure(dual_key_config())

      # Rotate
      capture_io(fn ->
        Mix.Tasks.Slackex.RotateKey.run([])
      end)

      # Remove retired key -- only new primary key remains
      Slackex.Vault.reconfigure(new_key_only_config())

      # Data should still be readable with only the new key
      assert Repo.get!(Slackex.Chat.Message, message.id).content == "will survive rotation"
    end
  end

  # ---------------------------------------------------------------------------
  # Vault config helpers
  # ---------------------------------------------------------------------------

  defp dual_key_config do
    [
      ciphers: [
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V2", key: @new_key},
        retired: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: @original_key}
      ]
    ]
  end

  defp new_key_only_config do
    [
      ciphers: [
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V2", key: @new_key}
      ]
    ]
  end

  # ---------------------------------------------------------------------------
  # Data helpers
  # ---------------------------------------------------------------------------

  defp get_raw_encrypted(table, column, id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [id])

    value
  end

  defp insert_abuse_report(description, metadata) do
    reporter = insert(:user)
    reported = insert(:user)
    id = System.unique_integer([:positive]) + 1_000_000_000_000

    {:ok, report} =
      %Slackex.Chat.AbuseReport{id: id}
      |> Slackex.Chat.AbuseReport.changeset(%{
        reporter_id: reporter.id,
        reported_user_id: reported.id,
        category: "spam",
        description: description,
        metadata: metadata
      })
      |> Repo.insert()

    report
  end
end
