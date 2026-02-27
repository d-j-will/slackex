defmodule Mix.Tasks.Slackex.EncryptExisting do
  @moduledoc """
  Migrates existing plaintext data to encrypted form.

  Processes each table (messages, users, dm_requests, abuse_reports) by reading
  rows where the encrypted column is null and the plaintext column is not null,
  encrypting the value, and writing the encrypted result.

  Uses batched streaming (500 rows per batch) to avoid memory issues.

  ## Usage

      mix slackex.encrypt_existing
  """

  use Mix.Task

  alias Slackex.Repo

  @batch_size 500

  @shortdoc "Encrypt existing plaintext data in all tables"
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("[EncryptExisting] Starting plaintext data encryption")

    encrypt_messages()
    encrypt_users()
    encrypt_dm_requests()
    encrypt_abuse_reports()

    Mix.shell().info("[EncryptExisting] Migration complete")
  end

  # ---------------------------------------------------------------------------
  # Messages: content -> encrypted_content
  # ---------------------------------------------------------------------------

  defp encrypt_messages do
    encrypt_table(
      "messages",
      "content",
      "encrypted_content",
      &encrypt_binary/1
    )
  end

  # ---------------------------------------------------------------------------
  # Users: email -> encrypted_email + email_hash
  # ---------------------------------------------------------------------------

  defp encrypt_users do
    total =
      fetch_batches("users", "email", "encrypted_email", fn rows ->
        Enum.each(rows, fn [id, plaintext_email] ->
          {:ok, encrypted} = Slackex.Encrypted.Binary.dump(plaintext_email)
          {:ok, hashed} = Slackex.Encrypted.HMAC.dump(plaintext_email)

          Repo.query!(
            "UPDATE users SET encrypted_email = $1, email_hash = $2 WHERE id = $3",
            [encrypted, hashed, id]
          )
        end)
      end)

    Mix.shell().info("[EncryptExisting] users: encrypted #{total} rows")
  end

  # ---------------------------------------------------------------------------
  # DM Requests: preview_text -> encrypted_preview_text
  # ---------------------------------------------------------------------------

  defp encrypt_dm_requests do
    encrypt_table(
      "dm_requests",
      "preview_text",
      "encrypted_preview_text",
      &encrypt_binary/1
    )
  end

  # ---------------------------------------------------------------------------
  # Abuse Reports: description -> encrypted_description,
  #                metadata   -> encrypted_metadata
  # ---------------------------------------------------------------------------

  defp encrypt_abuse_reports do
    total_desc =
      encrypt_table(
        "abuse_reports",
        "description",
        "encrypted_description",
        &encrypt_binary/1
      )

    total_meta =
      encrypt_table(
        "abuse_reports",
        "metadata",
        "encrypted_metadata",
        &encrypt_map/1
      )

    if total_desc > 0 or total_meta > 0 do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Generic helpers
  # ---------------------------------------------------------------------------

  defp encrypt_table(table, plaintext_col, encrypted_col, encrypt_fn) do
    total =
      fetch_batches(table, plaintext_col, encrypted_col, fn rows ->
        Enum.each(rows, fn [id, plaintext_value] ->
          encrypted = encrypt_fn.(plaintext_value)

          Repo.query!(
            "UPDATE #{table} SET #{encrypted_col} = $1 WHERE id = $2",
            [encrypted, id]
          )
        end)
      end)

    Mix.shell().info("[EncryptExisting] #{table}.#{plaintext_col}: encrypted #{total} rows")
    total
  end

  defp fetch_batches(table, plaintext_col, encrypted_col, process_fn) do
    do_fetch_batches(table, plaintext_col, encrypted_col, process_fn, 0, 0, 0)
  end

  defp do_fetch_batches(table, plaintext_col, encrypted_col, process_fn, offset, batch_num, total) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT id, #{plaintext_col}
        FROM #{table}
        WHERE #{encrypted_col} IS NULL
          AND #{plaintext_col} IS NOT NULL
        ORDER BY id
        LIMIT $1
        OFFSET $2
        """,
        [@batch_size, offset]
      )

    case rows do
      [] ->
        total

      batch ->
        batch_count = length(batch)
        new_batch_num = batch_num + 1
        new_total = total + batch_count

        Mix.shell().info(
          "[EncryptExisting] #{table}: batch #{new_batch_num}, #{batch_count} rows (#{new_total} total)"
        )

        process_fn.(batch)

        do_fetch_batches(
          table,
          plaintext_col,
          encrypted_col,
          process_fn,
          offset + batch_count,
          new_batch_num,
          new_total
        )
    end
  end

  defp encrypt_binary(plaintext) when is_binary(plaintext) do
    {:ok, encrypted} = Slackex.Encrypted.Binary.dump(plaintext)
    encrypted
  end

  defp encrypt_map(value) do
    # metadata is stored as jsonb -- Postgres returns it as a decoded map via Postgrex
    map =
      cond do
        is_map(value) -> value
        is_binary(value) -> Jason.decode!(value)
        true -> %{}
      end

    {:ok, encrypted} = Slackex.Encrypted.Map.dump(map)
    encrypted
  end
end
