defmodule Slackex.VaultTest do
  use ExUnit.Case, async: true

  alias Slackex.Encrypted

  # A "Vault is alive in the supervision tree" test lived here. Every
  # round-trip below goes through the same GenServer, so a Vault missing from
  # the tree fails them first and louder -- it was a precondition check for
  # tests that already imply it. Same reasoning retired the "vector extension
  # is enabled" test in the infrastructure suite.

  describe "Encrypted.Binary round-trip" do
    test "encrypting then decrypting a binary returns the original value" do
      original = "sensitive-user-data"

      {:ok, encrypted} = Encrypted.Binary.dump(original)
      {:ok, decrypted} = Encrypted.Binary.load(encrypted)

      assert decrypted == original
    end

    test "encrypted form differs from plaintext" do
      original = "sensitive-user-data"

      {:ok, encrypted} = Encrypted.Binary.dump(original)

      refute encrypted == original
    end
  end

  describe "Encrypted.Map round-trip" do
    test "encrypting then decrypting a map returns the original map" do
      original = %{"key" => "value", "nested" => %{"a" => 1}}

      {:ok, encrypted} = Encrypted.Map.dump(original)
      {:ok, decrypted} = Encrypted.Map.load(encrypted)

      assert decrypted == original
    end
  end

  describe "Encrypted.HMAC" do
    test "identical inputs produce identical hashes" do
      input = "user@example.com"

      {:ok, hash_a} = Encrypted.HMAC.dump(input)
      {:ok, hash_b} = Encrypted.HMAC.dump(input)

      assert hash_a == hash_b
    end

    test "different inputs produce different hashes" do
      {:ok, hash_a} = Encrypted.HMAC.dump("user@example.com")
      {:ok, hash_b} = Encrypted.HMAC.dump("other@example.com")

      refute hash_a == hash_b
    end
  end
end
