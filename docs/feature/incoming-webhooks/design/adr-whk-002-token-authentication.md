# ADR-WHK-002: Token Authentication Strategy

## Status

Accepted

## Context

Webhook endpoints need authentication that works for machine-to-machine communication without interactive login. The token must be secure against enumeration, resistant to database compromise (leaked hashes should not allow sending), and simple enough for external services (GitHub Actions, curl) to use without SDK or OAuth flow.

The project already has two auth mechanisms: session-based authentication (browser login) and JWT (API auth via Guardian). Neither is suitable for webhooks -- sessions require interactive login, and JWTs require a login-then-use flow plus token refresh.

## Decision

Token-in-URL authentication with SHA-256 hashing at rest.

- Token format: `whk_` prefix + 32 bytes from `:crypto.strong_rand_bytes/1` encoded as URL-safe Base64 (43 characters after encoding, ~47 total with prefix)
- Storage: SHA-256 hash of the full token (prefix included) stored in the `token_hash` column
- Lookup: on each request, hash the incoming `:token` path parameter and query by `token_hash`
- Display: plaintext token shown once on the creation confirmation page; never stored or retrievable

## Alternatives Considered

### Alternative A: HMAC signature verification (Slack-style)

Each request includes a signature header computed from a shared secret + request body. The server recomputes the HMAC and compares.

**Evaluation:**
- (+) Verifies request integrity (body tampering detected)
- (+) Secret never transmitted in the request
- (-) Significantly more complex for callers -- must compute HMAC in CI scripts, curl one-liners become multi-line with openssl
- (-) Requires timestamp-based replay protection (additional complexity)
- (-) Overkill for a single-developer homelab application where HTTPS is already enforced

**Rejected because:** Violates the simplicity quality attribute. GitHub Actions would need a custom script to compute HMAC signatures. The curl example on the confirmation page would be unusable. HTTPS already provides transport integrity.

### Alternative B: API key in Authorization header

Token sent as `Authorization: Bearer whk_...` header instead of in the URL path.

**Evaluation:**
- (+) Industry standard for API authentication
- (+) Token not logged in URL access logs (less exposure)
- (-) Slightly more complex for callers (must set header)
- (-) Some webhook-sending tools have limited header customization
- (-) GitHub Actions `curl` would need explicit `-H "Authorization: Bearer ..."` flag

**Rejected because:** Minor ergonomic disadvantage for the primary use case (GitHub Actions curl). The URL-in-path approach matches the Slack/Discord webhook convention that users already understand. URL access logs are not a concern -- Caddy reverse proxy logs are controlled by the same admin who creates webhooks.

### Alternative C: Plaintext token storage (no hashing)

Store the token in plaintext in the database. Simplifies lookup (direct equality check).

**Evaluation:**
- (+) Simpler implementation
- (-) Database compromise exposes all webhook tokens immediately
- (-) Violates security-by-design principle (defense in depth)

**Rejected because:** Hashing is trivial (single `:crypto.hash/2` call on each path) and provides meaningful defense-in-depth against database compromise. The cost is negligible.

## Consequences

### Positive

- **Simple for callers**: URL contains everything needed. `curl -X POST -H "Content-Type: application/json" -d '{"text": "hello"}' https://host/api/webhooks/whk_...` -- no headers, no SDK.
- **Secure at rest**: Database compromise exposes only SHA-256 hashes, which are computationally infeasible to reverse (256-bit entropy input).
- **No token enumeration**: 32 bytes of randomness = 2^256 possible tokens. Brute force is infeasible.
- **Familiar pattern**: Matches Slack, Discord, and other webhook providers. Users know the mental model.

### Negative

- **Token in URL**: The plaintext token appears in the URL, which means it may appear in HTTP access logs on the reverse proxy (Caddy). This is acceptable because: (a) the same admin controls both Slackex and Caddy, (b) HTTPS encrypts the URL in transit, (c) this matches the industry standard for webhook URLs.
- **Show-once**: The plaintext token is only available on the creation confirmation page. If the user navigates away without copying, they must regenerate. This is intentional security behavior (matches GitHub personal access tokens, Slack webhook URLs).
- **One hash per request**: Every webhook delivery computes a SHA-256 hash. This is negligible (~microseconds) and not a performance concern at 60 req/min.
