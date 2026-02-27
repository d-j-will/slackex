defmodule Slackex.Encrypted.HMAC do
  @moduledoc """
  Ecto type for HMAC-hashed fields.

  Produces a deterministic, non-reversible hash for exact-match lookups
  on encrypted columns (e.g., searching by email without decrypting).
  """

  use Cloak.Ecto.HMAC, otp_app: :slackex
end
