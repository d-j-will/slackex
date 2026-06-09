defmodule Mix.Tasks.Slackex.RotateKey do
  use Boundary, classify_to: Slackex.MixTasks

  @moduledoc """
  Re-encrypts all encrypted fields in all schemas with the current primary key.

  This task wraps `Cloak.Ecto.Migrator.migrate/2` to re-encrypt every row in
  every table that contains Cloak-encrypted fields. After rotation, all data
  will be encrypted with the Vault's current primary cipher (the first cipher
  in the `:ciphers` list).

  ## Prerequisites

  Before running this task, configure the Vault with both the new primary key
  and the retired key so that existing ciphertexts can be decrypted during
  migration:

      config :slackex, Slackex.Vault,
        ciphers: [
          default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V2", key: new_key},
          retired: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: old_key}
        ]

  ## Usage

      mix slackex.rotate_key
  """

  use Mix.Task

  alias Cloak.Ecto.Migrator

  @encrypted_schemas [
    Slackex.Chat.Message,
    Slackex.Accounts.User,
    Slackex.Chat.DMRequest,
    Slackex.Chat.AbuseReport
  ]

  @shortdoc "Re-encrypt all fields in all encrypted tables with current primary key"
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info(
      "[RotateKey] Starting key rotation for #{length(@encrypted_schemas)} schemas"
    )

    Enum.each(@encrypted_schemas, &migrate_schema/1)

    Mix.shell().info("[RotateKey] Key rotation complete")
  end

  defp migrate_schema(schema) do
    table_name = schema.__schema__(:source)
    Mix.shell().info("[RotateKey] Migrating #{table_name} (#{inspect(schema)})...")

    Migrator.migrate(Slackex.Repo, schema)

    Mix.shell().info("[RotateKey] #{table_name} migration complete")
  end
end
