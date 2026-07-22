# Andon relay conformance fixtures — provenance

`grammar.json` in this directory is a **byte-identical copy** of the relay
conformance suite that ships with the andon service. It is vendored here so
slackex (relay #1) can import it into its own test suite — this is the
conformance claim (ADR-0002: "a relay conformance suite ships with the
service").

- **Source repo:** github.com/davewil/andon (local: `~/dev/elixir/andon-proto-claude`)
- **Source path:** `priv/relay_conformance/v1/grammar.json`
- **Contract:** `relay-conformance`, version `1`
- **Copied at source commit:** `7244a5ae039ddca04badf096b944eec20f95395a`
- **sha256:** `d8dd264e1a39ca01beadf3edc9848507573f1f47a1bbe46a7f4c347ac3c67d49`

Do not edit `grammar.json` locally. If the contract changes, re-copy the file
from the source repo and update the commit + sha above. A local divergence
would silently break the conformance claim.

## Scope of the claim in v1

`Slackex.Andon.GrammarTest` iterates every entry in `grammar_cases` against
`Slackex.Andon.Grammar.parse/1`. It exercises the **text-grammar half** of C1.

The fixture's `identical_event_rule` (the optional `/pull` slash-command
adapter and the text grammar must produce byte-equal domain events) is
**deferred**: slackex v1 ships the text grammar only, so there is no second
input method to compare against. When a `/pull` adapter is added, its output
must be asserted byte-equal to `Grammar.parse/1`'s across the full domain
event (excluding `event_id`/`occurred_at`) to close the claim.
