defmodule Slackex.Encrypted.Map do
  @moduledoc """
  Ecto type for encrypted map fields.

  Serializes maps to JSON, encrypts the result, and stores ciphertext.
  Decrypts and deserializes transparently on load.
  Backed by `Slackex.Vault` with AES-GCM-256.
  """

  use Cloak.Ecto.Map, vault: Slackex.Vault
end
