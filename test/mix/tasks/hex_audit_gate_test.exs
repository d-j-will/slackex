defmodule Mix.Tasks.Slackex.HexAuditGateTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Slackex.HexAuditGate

  @clean_output "No retired or security advisory packages found\n"

  @allowlisted_output """
  Retired:
    earmark 1.4.48 - (deprecated) Earmark is no longer maintained. Migrate to a replacement, for example MDEx (https://hex.pm/packages/mdex).

  Advisories:
    earmark 1.4.48 - EEF-CVE-2026-48591 (MEDIUM)
      aka: CVE-2026-48591, GHSA-52mm-h59v-f3c7
      Stored XSS via unescaped HTML attribute values in earmark
      https://osv.dev/vulnerability/EEF-CVE-2026-48591

  Found retired packages
  Found packages with security advisories
  """

  @new_retirement_output """
  Retired:
    some_pkg 1.0.0 - (deprecated) some_pkg is no longer maintained.

  Found retired packages
  """

  @new_advisory_output """
  Advisories:
    some_pkg 1.0.0 - EEF-CVE-2099-99999 (HIGH)
      aka: CVE-2099-99999, GHSA-zzzz-zzzz-zzzz
      Made-up vulnerability for testing
      https://osv.dev/vulnerability/EEF-CVE-2099-99999

  Found packages with security advisories
  """

  @mixed_output """
  Retired:
    earmark 1.4.48 - (deprecated) Earmark is no longer maintained.

  Advisories:
    earmark 1.4.48 - EEF-CVE-2026-48591 (MEDIUM)
      aka: CVE-2026-48591, GHSA-52mm-h59v-f3c7
      Stored XSS via unescaped HTML attribute values in earmark

    some_pkg 1.0.0 - EEF-CVE-2099-99999 (HIGH)
      aka: CVE-2099-99999, GHSA-zzzz-zzzz-zzzz
      Made-up vulnerability for testing

  Found retired packages
  Found packages with security advisories
  """

  test "passes through a clean exit code regardless of output" do
    assert HexAuditGate.evaluate(@clean_output, 0) == :ok
  end

  test "accepts findings that are entirely on the allowlist" do
    assert {:accepted, message} = HexAuditGate.evaluate(@allowlisted_output, 1)
    assert message =~ "earmark"
    assert message =~ "CVE-2026-48591"
  end

  test "matches an advisory block by any alias, not just its primary id" do
    # The allowlist only keys on "CVE-2026-48591", but the block also carries
    # "GHSA-52mm-h59v-f3c7" and the EEF-CVE-2026-48591 primary id — all three
    # refer to the same finding and must not be treated as 3 separate ones.
    assert {:accepted, _message} = HexAuditGate.evaluate(@allowlisted_output, 1)
  end

  test "fails on a retirement not present on the allowlist" do
    assert {:error, message} = HexAuditGate.evaluate(@new_retirement_output, 1)
    assert message =~ "some_pkg"
    assert message =~ "unlisted retirements"
  end

  test "fails on an advisory not present on the allowlist" do
    assert {:error, message} = HexAuditGate.evaluate(@new_advisory_output, 1)
    assert message =~ "CVE-2099-99999"
    assert message =~ "unlisted advisories"
  end

  test "fails on the unlisted finding while accepting the listed one in the same run" do
    assert {:error, message} = HexAuditGate.evaluate(@mixed_output, 1)
    refute message =~ "unlisted retirements: [\"earmark\"]"
    assert message =~ "CVE-2099-99999"
  end
end
