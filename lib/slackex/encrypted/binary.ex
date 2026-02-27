defmodule Slackex.Encrypted.Binary do
  @moduledoc """
  Ecto type for encrypted binary fields.

  Stores ciphertext in the database, decrypts transparently on load.
  Backed by `Slackex.Vault` with AES-GCM-256.
  """

  use Cloak.Ecto.Binary, vault: Slackex.Vault
end
