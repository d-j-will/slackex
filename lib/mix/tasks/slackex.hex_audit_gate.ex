defmodule Mix.Tasks.Slackex.HexAuditGate do
  use Boundary, classify_to: Slackex.MixTasks

  @shortdoc "Runs mix hex.audit, allowing only pre-approved findings through"

  @moduledoc """
  Interim wrapper around `mix hex.audit`.

  Released Hex (verified against 2.5.0, the latest release as of 2026-07-08)
  has no built-in way to acknowledge a specific advisory or retirement —
  `ignore_advisories`/`ignore_retirements` only exist on Hex's unreleased
  `main` branch. Until that ships (or the offending dependency is replaced),
  this task re-implements the same idea by text-parsing `mix hex.audit`'s
  output and diffing it against the allowlists below.

  Any finding not on the allowlist fails the task (preserving the gate for
  new advisories). Delete this task and go back to plain `mix hex.audit` once
  Hex ships real ignore support, or once every allowlisted dependency is
  replaced/upgraded. Tracked in slackex-5f7.
  """

  use Mix.Task

  # {reason, revisit date} — revisit even if nothing forces you to.
  @allowed_retirements %{
    "earmark" =>
      {"No non-retired earmark release exists (deprecated upstream, migrate to MDEx). " <>
         "Core to the markdown-rendering feature (custom Scrubber + contract tests); " <>
         "migration tracked as its own follow-up, not a drop-in bump.", "2026-10-08"}
  }

  @allowed_advisory_ids %{
    "CVE-2026-48591" =>
      {"earmark stored-XSS via unescaped HTML attribute values. Mitigated in practice: " <>
         "Slackex.Markdown.Scrubber re-parses earmark's output with a real HTML parser " <>
         "(mochiweb_html) and re-escapes attribute values on serialization, so an " <>
         "attribute-value breakout becomes a new node subject to the same tag/attribute " <>
         "allowlist. No fixed earmark release exists (upstream: none planned). Verified " <>
         "against the advisory's own PoC payload — see " <>
         "test/slackex/markdown/markdown_test.exs \"neutralizes earmark's " <>
         "unescaped-attribute-value stored XSS\".", "2026-10-08"}
  }

  @impl Mix.Task
  def run(_args) do
    {output, exit_code} = System.cmd("mix", ["hex.audit"], stderr_to_stdout: true)
    Mix.shell().info(output)

    case evaluate(output, exit_code) do
      :ok ->
        :ok

      {:accepted, message} ->
        Mix.shell().info(message)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc """
  Pure decision core: given `mix hex.audit`'s raw output and exit code,
  decides whether every finding is pre-approved. No IO — takes text in,
  returns a decision out.
  """
  def evaluate(_output, 0), do: :ok

  def evaluate(output, _nonzero_exit_code) do
    unknown_retirements = unknown_retirements(output)
    unknown_advisory_blocks = unknown_advisory_blocks(output)

    case {unknown_retirements, unknown_advisory_blocks} do
      {[], []} ->
        {:accepted, "\nAll findings are pre-approved (slackex-5f7):\n" <> format_allowlist()}

      {unknown_retirements, unknown_advisory_blocks} ->
        unknown_advisory_ids = Enum.map(unknown_advisory_blocks, &first_advisory_id/1)

        {:error,
         """
         mix hex.audit found issues NOT on the slackex-5f7 allowlist:
           unlisted retirements: #{inspect(unknown_retirements)}
           unlisted advisories: #{inspect(unknown_advisory_ids)}

         Either fix the dependency, or add a justified, dated entry to the
         allowlist in lib/mix/tasks/slackex.hex_audit_gate.ex.
         """}
    end
  end

  defp unknown_retirements(output) do
    ~r/^\s*([a-z0-9_]+)\s+\S+\s+-\s+\(deprecated\)/m
    |> Regex.scan(output)
    |> Enum.map(fn [_, package] -> package end)
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(@allowed_retirements, &1))
  end

  # Each advisory block lists several aliases for the SAME finding (its
  # primary EEF-CVE id, plus "aka: CVE-..., GHSA-..."). Split on blank lines
  # so the block is covered if ANY alias is allowlisted, rather than
  # requiring every alias to be listed individually.
  defp unknown_advisory_blocks(output) do
    output
    |> String.split(~r/\n\s*\n/)
    |> Enum.filter(&(&1 =~ ~r/\bCVE-\d{4}-\d+\b/ or &1 =~ ~r/\bGHSA-[a-z0-9-]+\b/))
    |> Enum.reject(fn block ->
      Enum.any?(advisory_ids(block), &Map.has_key?(@allowed_advisory_ids, &1))
    end)
  end

  defp advisory_ids(text) do
    ~r/\b(CVE-\d{4}-\d+|GHSA-[a-z0-9-]+)\b/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  defp first_advisory_id(block) do
    case advisory_ids(block) do
      [id | _] -> id
      [] -> block
    end
  end

  defp format_allowlist do
    retirement_lines =
      for {package, {reason, revisit}} <- @allowed_retirements do
        "  - #{package} (retired): #{reason} [revisit #{revisit}]"
      end

    advisory_lines =
      for {id, {reason, revisit}} <- @allowed_advisory_ids do
        "  - #{id}: #{reason} [revisit #{revisit}]"
      end

    Enum.join(retirement_lines ++ advisory_lines, "\n")
  end
end
