# Andon relay conformance fixtures — provenance

`grammar.json` in this directory is a **byte-identical copy** of the relay
conformance suite that ships with the andon service. It is vendored here so
slackex (relay #1) can import it into its own test suite — this is the
conformance claim (ADR-0002: "a relay conformance suite ships with the
service").

- **Source repo:** github.com/davewil/andon (local: `~/dev/elixir/andon-proto-claude`)
- **Source path:** `priv/relay_conformance/v1/grammar.json`
- **Contract:** `relay-conformance`, version `1`
- **Copied at source commit:** `d52f8b0` (ENG-45, ADR-0016)
- **sha256:** `742e328eccf2e378a451af68e8aa8e7d1cdd0defdb169b97f62886c10c148227`

Re-vendored 2026-07-29 for ADR-0016 (the bare cord — an unclassed pull is a
valid pull). An unknown first word after the keyword is now SENTENCE, not an
error: the pull is created classless (`"class": null`) and the class is
settled afterwards in-thread. One prior expectation flipped (unknown class
word: correction → classless pull); corrections remain only where there is no
sentence to take. Previous pin: `a3924090` / `2d0866e5…`.

Re-vendored 2026-07-27 for ADR-0014 (the cord does not care about case, and an
attempt is never ignored). The keyword and class are now matched
case-insensitively, and a message that opens with the keyword but does not
complete a pull earns a correction rather than silence. Message-start-only is
unchanged. Previous pin: `7244a5ae` / `d8dd264e…`.

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
