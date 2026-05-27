# ADR-001: Decision fields stored as plaintext in Slice A

**Date:** 2026-05-27
**Status:** Accepted (Slice A only — explicitly time-boxed)
**Context:** Sous Slice A — event-stream tracer bullet

---

## Context

Chat `Message.content` is encrypted at rest via Cloak (`Slackex.Encrypted.Binary`), with a
plaintext `search_content` companion column for FTS/GIN indexing.

Slice A introduces a `Decision` table (1:1 with a `:decision` `WorkItem`) holding `what`,
`why`, and `next` text. These fields are read by two surfaces on the hot path:

- the **In Service** board (renders the card title/facet; may surface decision detail), and
- the **decision card** rendered inline in chat.

The question: should `Decision.what/why/next` be Cloak-encrypted like message bodies, or stored
as plaintext?

## Decision

For **Slice A**, store `Decision.what / why / next` as **plaintext** `text` columns.

## Rationale

- The board and decision-card renders need to read these fields cheaply and frequently;
  encryption adds decrypt-on-read cost and rules out indexing/search later without a
  `search_content`-style companion.
- Slice A is a tracer bullet whose purpose is proving the chat → work-item → board spine, not
  hardening data-at-rest. Adding the encryption + companion-column machinery now is scope the
  slice does not need.
- The decision content is a deliberate, structured summary a user chooses to publish to a
  channel (it is already posted as a visible chat message), not private message correspondence.

## Consequences

### Positive
- Simple schema; fast reads on the board and card render paths.
- Leaves the door open to indexing/searching decisions later without fighting encryption.

### Negative / Risk
- Decision text is **not** encrypted at rest, diverging from the message-body encryption pattern.
  If decisions come to carry sensitive content, this is a gap.

### Revisit trigger (binding)
Before Sous graduates past the tracer-bullet slices — or the first time a decision is expected to
carry sensitive/regulated content — re-evaluate encrypting `Decision.what/why/next`. If adopted,
mirror the `Message` pattern: Cloak-encrypted column + a plaintext companion column only if
search/indexing is required. This ADR's "plaintext" decision is scoped to Slice A and must not be
silently inherited by later slices.
