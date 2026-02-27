defmodule Slackex.Vault do
  @moduledoc """
  Cloak Vault for field-level encryption using AES-GCM-256.

  Configured via application environment per deployment target:
  - dev/test: static key in config files
  - prod: CLOAK_KEY environment variable via runtime.exs
  """

  use Cloak.Vault, otp_app: :slackex
end
