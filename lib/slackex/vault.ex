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
  2. Set environment variables:
     - `CLOAK_KEY` — the new key
     - `CLOAK_KEY_TAG` — a new unique tag (e.g. `"AES.GCM.V2"`)
     - `CLOAK_RETIRED_KEY` — the old key
     - `CLOAK_RETIRED_KEY_TAG` — the tag used when data was originally encrypted
       (e.g. `"AES.GCM.V1"`)
  3. Restart the application (Vault picks up both keys via runtime.exs)
  4. Run `mix slackex.rotate_key` to re-encrypt all data with the new primary key
  5. Once rotation completes, remove `CLOAK_RETIRED_KEY` and `CLOAK_RETIRED_KEY_TAG`

  Tags are critical: Cloak uses them as binary prefixes on ciphertext to
  match the correct cipher for decryption. The retired key MUST keep its
  original tag so existing ciphertexts can be decoded.
  """

  # Leaf utility: freely depended upon (in: false), depends on nothing in-app.
  use Boundary, deps: [], check: [in: false]

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
