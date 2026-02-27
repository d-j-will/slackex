defmodule Slackex.Vault do
  @moduledoc """
  Cloak Vault for field-level encryption using AES-GCM-256.

  Configured via application environment per deployment target:
  - dev/test: static key in config files
  - prod: CLOAK_KEY environment variable via runtime.exs

  Supports key rotation by configuring multiple ciphers:
  - The first cipher (`:default`) encrypts all new data
  - Retired ciphers decrypt legacy ciphertexts during the transition

  ## Key Rotation Procedure

  1. Generate a new 32-byte key: `:crypto.strong_rand_bytes(32) |> Base.encode64()`
  2. Set the new key as `CLOAK_KEY` environment variable
  3. Move the old key to `CLOAK_RETIRED_KEY` environment variable
  4. Restart the application (Vault picks up both keys via runtime.exs)
  5. Run `mix slackex.rotate_key` to re-encrypt all data with the new primary key
  6. Once rotation completes, `CLOAK_RETIRED_KEY` can be removed
  """

  use Cloak.Vault, otp_app: :slackex

  @doc """
  Reconfigures the Vault with new cipher settings at runtime.

  Updates both the GenServer state and the ETS config cache so that
  subsequent encrypt/decrypt calls use the new ciphers immediately.

  Used during key rotation and in tests to swap cipher keys without
  restarting the supervision tree.
  """
  def reconfigure(config) do
    GenServer.call(__MODULE__, {:reconfigure, config})
  end

  @impl GenServer
  def handle_call(:save_config, _from, config) do
    Cloak.Vault.save_config(:"#{__MODULE__}.Config", config)
    {:reply, :ok, config}
  end

  def handle_call({:reconfigure, new_config}, _from, _old_config) do
    Cloak.Vault.save_config(:"#{__MODULE__}.Config", new_config)
    {:reply, :ok, new_config}
  end
end
