# Data Security and Encryption for a Real-Time Chat Application (Elixir/Phoenix)

**Research Type:** Deep-Dive Analysis
**Date:** 2026-02-27
**Researcher:** Nova (nw-researcher)
**Application Context:** Slackex -- a Slack-like chat application built with Elixir 1.17, Phoenix 1.8, Phoenix LiveView 1.1, PostgreSQL, Redis, and Bandit

---

## Executive Summary

This research examines the full spectrum of data security and encryption options for a real-time chat application built on the Elixir/Phoenix stack. The analysis covers encryption at rest (database-level, application-level), end-to-end encryption protocols (Signal, Matrix/Olm/Megolm), transport security (TLS 1.3, WebSocket hardening), data protection architecture patterns (envelope encryption, zero-knowledge, searchable encryption), Elixir ecosystem tools (Cloak, :crypto), and compliance considerations (GDPR, SOC 2, ISO 27001).

**Key findings:**

1. **Encryption at rest is the highest-value, lowest-complexity first step.** Cloak.Ecto provides transparent field-level encryption for Ecto schemas with AES-GCM, requiring minimal application changes. This should be the first security layer implemented.

2. **Full end-to-end encryption (E2EE) is architecturally incompatible with many Slack-like features** (server-side search, message editing history, link previews, admin compliance tools). Signal and WhatsApp chose E2EE because they prioritize privacy over enterprise features. Slack chose server-side encryption because they prioritize enterprise functionality. A Slack-like app should follow Slack's model.

3. **Transport security via TLS 1.3 is non-negotiable and straightforward** in Phoenix/Bandit. This protects all data in transit including WebSocket connections.

4. **Envelope encryption with a cloud KMS** (AWS KMS, GCP Cloud KMS) provides the strongest key management for encryption at rest, separating data encryption keys from key encryption keys.

5. **Compliance frameworks (GDPR, SOC 2, ISO 27001) require encryption but do not mandate E2EE.** Encryption at rest + TLS in transit satisfies the encryption controls in all three frameworks.

**Recommended implementation order:**
- **Phase 1 (Immediate):** TLS 1.3 for all connections + Cloak.Ecto field encryption for PII and message content
- **Phase 2 (Near-term):** Envelope encryption with KMS + secure key rotation + cryptographic erasure for GDPR
- **Phase 3 (If needed):** Evaluate E2EE for specific high-security channels using a hybrid approach

**Confidence Distribution:** High (5 areas), Medium (3 areas), Low (1 area -- searchable encryption practicality)

---

## Table of Contents

1. [Encryption at Rest](#1-encryption-at-rest)
2. [End-to-End Encryption (E2E)](#2-end-to-end-encryption-e2e)
3. [Transport Security](#3-transport-security)
4. [Data Protection Architecture Patterns](#4-data-protection-architecture-patterns)
5. [Elixir/Phoenix Ecosystem](#5-elixirphoenix-ecosystem)
6. [Compliance and Regulatory Context](#6-compliance-and-regulatory-context)
7. [Practical Recommendations](#7-practical-recommendations)
8. [Knowledge Gaps](#8-knowledge-gaps)
9. [Sources](#9-sources)

---

## 1. Encryption at Rest

### 1.1 PostgreSQL Native Encryption Options

PostgreSQL provides several layers of encryption, but does not natively include transparent data encryption (TDE) in the way Oracle or SQL Server do.

**Confidence: High** (5 sources)

#### pgcrypto Extension (Column-Level)

The `pgcrypto` module enables encryption of specific database columns. Data is encrypted and decrypted at the SQL level using functions like `pgp_sym_encrypt()` and `pgp_sym_decrypt()`.

| Aspect | Detail |
|--------|--------|
| Granularity | Per-column |
| Key management | Application provides decryption key in SQL queries |
| Performance | Encryption/decryption happens on the database server |
| Query support | Cannot use indexes on encrypted columns; must decrypt to query |
| Security concern | Data and keys are briefly exposed on the server during decryption |

**Limitations:** pgcrypto requires modifying SQL statements throughout the application, keys are passed in queries (visible in logs if not careful), and it cannot leverage database indexes on encrypted columns [1][2][3].

#### Filesystem/Disk-Level Encryption

PostgreSQL documentation recommends filesystem-level encryption (Linux: dm-crypt + LUKS; macOS: FileVault; FreeBSD: geli/gbde) as an alternative to column-level encryption. This encrypts the entire database storage transparently.

| Aspect | Detail |
|--------|--------|
| Granularity | Entire filesystem or disk partition |
| Transparency | Fully transparent to PostgreSQL and applications |
| Protection scope | Protects against physical theft of storage media |
| Limitation | Does NOT protect against attacks while the filesystem is mounted |
| Limitation | Does NOT protect against a compromised database server |

**Assessment:** Disk encryption is a baseline defense-in-depth measure but insufficient as the sole encryption strategy for a chat application. It protects against physical theft but not against database compromise, SQL injection, or insider threats [1][3].

#### Percona pg_tde (Transparent Data Encryption)

Percona released pg_tde as the first open-source TDE extension for PostgreSQL, reaching production-ready status in 2025 with PostgreSQL 17+ support. WAL encryption reached General Availability in Percona Distribution for PostgreSQL 17.5.3.

| Aspect | Detail |
|--------|--------|
| Granularity | Table-level and WAL-level |
| Transparency | Fully transparent to application code |
| Status | Production-ready as of 2025; packaged with Percona Distribution for PostgreSQL 17+ |
| Key management | Supports integration with external key managers |
| Compliance | Helps meet GDPR, HIPAA, SOX, PCI DSS v4.0 |
| Limitation | Requires Percona Distribution for PostgreSQL; not yet in upstream vanilla PostgreSQL |

**Assessment:** pg_tde is a viable option if you use Percona's PostgreSQL distribution. It provides transparent encryption without application changes but ties you to a specific PostgreSQL distribution [4][5].

### 1.2 Application-Level Encryption (Cloak/Vault for Ecto)

**Confidence: High** (4 sources)

Cloak and Cloak.Ecto provide transparent, application-level field encryption for Elixir/Ecto applications. This is the most natural fit for the Slackex stack.

#### How Cloak.Ecto Works

1. You define custom Ecto types that wrap Cloak's encryption (e.g., `MyApp.Encrypted.Binary`)
2. Schema fields use these custom types instead of standard Ecto types
3. On write: Cloak encrypts values into binary blobs using the configured algorithm before Ecto writes to PostgreSQL
4. On read: Cloak automatically decrypts values when Ecto loads records
5. Each ciphertext includes metadata about the algorithm and key used, enabling transparent key rotation

```elixir
# Define an encrypted type
defmodule MyApp.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: MyApp.Vault
end

# Use in schema
schema "messages" do
  field :body, MyApp.Encrypted.Binary  # Encrypted at rest
  field :body_hash, Cloak.Ecto.SHA256  # Searchable hash
end
```

#### Supported Algorithms

| Algorithm | Mode | Key Size | Notes |
|-----------|------|----------|-------|
| AES-GCM | Authenticated encryption | 128/192/256-bit | Recommended; provides both confidentiality and integrity |
| AES-CTR | Stream cipher mode | 128/192/256-bit | Confidentiality only; no built-in integrity check |

#### Key Features

- **Automatic IV generation:** Uses `:crypto.strong_rand_bytes` for unique initialization vectors per ciphertext
- **Key rotation:** `mix cloak.migrate` task re-encrypts data with new keys; old keys retained for reading legacy ciphertexts
- **Hash-based searching:** `Cloak.Ecto.SHA256` and `Cloak.Ecto.HMAC` types create deterministic hashes for querying encrypted fields
- **Algorithm metadata in ciphertext:** Each encrypted value includes which algorithm/key was used, enabling graceful key rotation

#### Limitations

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| Encrypted fields are not directly queryable | Cannot use WHERE, ORDER BY, JOIN on encrypted columns | Use SHA256/HMAC hash columns as search proxies |
| No per-user encryption keys | Cannot encrypt different users' data with different keys (Ecto.Type limitation) | Use envelope encryption pattern at application level |
| Data is plaintext in Ecto structs at runtime | Memory dumps could expose decrypted data | Minimize struct lifetime; use secure memory practices |
| Performance overhead | Encryption/decryption on every read/write | Benchmark; typically negligible for chat message volumes |
| Binary blob storage | Encrypted data stored as binary; no partial reads | Accept storage overhead |

#### Performance Implications

No published benchmarks exist specifically for Cloak.Ecto (see Knowledge Gaps). However, general observations from the community and PostgreSQL encryption research indicate:

- AES-GCM encryption/decryption is hardware-accelerated on modern CPUs (AES-NI instruction set), making per-message overhead minimal (sub-millisecond)
- The primary performance concern is not CPU overhead but loss of database-level query optimization on encrypted columns
- For a chat application, the message write/read pattern (sequential, by channel/conversation) aligns well with application-level encryption since messages are rarely queried by content at the database level

### 1.3 Key Management Strategies

**Confidence: High** (5 sources)

#### Envelope Encryption Pattern

Envelope encryption is the recommended pattern for managing encryption keys at scale. The concept: encrypt data with a Data Encryption Key (DEK), then encrypt the DEK with a Key Encryption Key (KEK) stored in a central key management service.

```
Plaintext Message
       |
       v
[Encrypt with DEK] --> Ciphertext + Encrypted DEK
       |                      |
       v                      v
  DEK (plaintext)        [Store together in DB]
       |
       v
[Encrypt DEK with KEK]  --> KEK never leaves KMS
```

**Process:**
1. Generate a DEK locally for each encryption operation (or per-user, per-channel, etc.)
2. Encrypt the data with the DEK using AES-256-GCM
3. Send the DEK to the KMS to be encrypted (wrapped) with the KEK
4. Store the encrypted data and the wrapped DEK together
5. The KEK never leaves the KMS

**Decryption:**
1. Retrieve the encrypted data and wrapped DEK
2. Send the wrapped DEK to the KMS for unwrapping
3. Use the plaintext DEK to decrypt the data
4. Discard the plaintext DEK from memory

#### KMS Options

| Service | Cost | FIPS Level | Integration | Notes |
|---------|------|------------|-------------|-------|
| AWS KMS | ~$1/key/month + $0.03/10K requests | FIPS 140-2 Level 2 (default) or Level 3 (CloudHSM) | AWS SDK for Elixir (ExAws) | Best if already on AWS |
| GCP Cloud KMS | ~$0.06/key version/month + $0.03/10K operations | FIPS 140-2 Level 1-3 depending on tier | Google Cloud client libraries | Best if already on GCP |
| Azure Key Vault | ~$0.03/10K operations | FIPS 140-2 Level 2 (Standard) or Level 3 (Premium) | Azure SDK | Best if already on Azure |
| HashiCorp Vault | Free (OSS) / Enterprise pricing | Software-based; can back onto HSM | HTTP API; Elixir client libraries exist | Best for multi-cloud or self-hosted |

#### HSM vs Cloud KMS

| Factor | Cloud KMS | Cloud HSM | On-Premises HSM |
|--------|-----------|-----------|-----------------|
| Cost | Low (~$1-5/month) | Medium (~$1-2/hour per instance) | High ($10K-50K+ upfront) |
| FIPS compliance | Level 1-2 | Level 3 | Level 3-4 |
| Operational complexity | Low (managed) | Medium | High (requires crypto engineers) |
| Latency | Low (API call) | Low (dedicated hardware) | Lowest (local) |
| Scalability | Auto-scaling | Manual provisioning | Hardware-limited |
| Best for | Most applications | Regulated industries | Maximum security requirements |

**Assessment for Slackex:** Cloud KMS (AWS KMS or equivalent) provides the best cost/security balance. HSM is warranted only if regulatory requirements demand FIPS 140-2 Level 3 or if the application handles government/financial data [6][7][8].

### 1.4 Which Data Fields Warrant Encryption

**Confidence: High** (4 sources)

| Data Category | Fields | Encrypt at Rest? | Rationale |
|---------------|--------|:-----------------:|-----------|
| **Message content** | body, attachments | Yes | Core sensitive data; user expectation of privacy |
| **User PII** | email, full name, phone number | Yes | Regulatory requirement (GDPR, CCPA); breach notification implications |
| **Authentication credentials** | password hashes, API tokens, OAuth tokens | Yes (but already hashed) | Defense in depth; bcrypt hashes are one-way but encryption adds a layer |
| **Session data** | session tokens, remember-me tokens | Yes | Prevents session hijacking from DB compromise |
| **Direct message metadata** | DM participant lists | Consider | Reveals relationship graphs; sensitive in some contexts |
| **Channel membership** | who is in which channel | No (typically) | Generally not considered sensitive PII |
| **Channel names/topics** | channel name, description | No (typically) | Usually organizational, not personal |
| **Timestamps** | created_at, updated_at | No | Low sensitivity; needed for queries and ordering |
| **Message metadata** | read receipts, reactions | No (typically) | Low sensitivity; high query frequency |

**Interpretation:** For a Slack-like application, the minimum encryption scope should cover message bodies, user PII (email, name), and authentication tokens. Expanding to DM metadata is advisable for privacy-conscious deployments.

---

## 2. End-to-End Encryption (E2E)

### 2.1 Signal Protocol (Double Ratchet + X3DH)

**Confidence: High** (5 sources)

The Signal Protocol is the gold standard for E2EE in messaging, powering Signal, WhatsApp, and Facebook Messenger's encrypted mode.

#### X3DH (Extended Triple Diffie-Hellman) Key Agreement

X3DH establishes a shared secret between two parties who may be asynchronous (one may be offline). It provides forward secrecy and cryptographic deniability.

**Key components:**
- **Identity Key (IK):** Long-term Curve25519 key pair; represents a user's identity
- **Signed Pre-Key (SPK):** Medium-term key pair, signed by IK; rotated periodically
- **One-Time Pre-Keys (OPK):** Single-use key pairs uploaded to the server in batches
- **Ephemeral Key (EK):** Generated fresh by the sender for each new session

**Process:**
1. Bob publishes his IK, SPK, and a batch of OPKs to the server
2. Alice fetches Bob's key bundle from the server
3. Alice performs 3-4 Diffie-Hellman calculations using combinations of these keys
4. Alice derives a shared secret and sends her initial message + ephemeral key to Bob
5. Bob performs the same DH calculations to derive the same shared secret

#### Double Ratchet Algorithm

Once X3DH establishes a shared secret, the Double Ratchet manages ongoing key evolution. It combines two ratchet mechanisms:

**Symmetric-Key Ratchet (Sending/Receiving Chains):**
- Each message derives a unique message key from a chain key via KDF
- After deriving the message key, the chain key advances (ratchets forward)
- Old chain keys are deleted; past message keys cannot be derived from current state

**Diffie-Hellman Ratchet (Root Chain):**
- Each message includes a new DH public key from the sender
- When a new DH public key is received, a DH ratchet step occurs
- The DH output is mixed into the root chain, generating new sending/receiving chain keys
- This provides "break-in recovery": even if an attacker captures current state, they lose access after the next DH ratchet step

**Security Properties:**
| Property | Description |
|----------|-------------|
| Forward secrecy | Compromise of long-term keys does not reveal past messages |
| Post-compromise recovery | After a state compromise, security is restored after DH ratchet steps |
| Per-message keys | Every message has a unique encryption key |
| Out-of-order delivery | Supports decryption of messages received out of order |
| Deniability | Mathematical deniability of message authorship |

#### Limitations for Group Chat

The Signal Protocol was designed for 1:1 conversations. For groups, Signal uses "Sender Keys" where each group member maintains a sending chain and distributes their sender key to all group members via pairwise Signal Protocol sessions. This has O(n) complexity for key distribution but O(1) for message sending.

### 2.2 Matrix/Olm/Megolm Protocol

**Confidence: High** (5 sources)

Matrix uses Olm (1:1) and Megolm (group) for E2EE, designed specifically for the challenges of group encrypted messaging.

#### Olm (1:1 Encryption)

Olm is an implementation of the Double Ratchet algorithm, similar to Signal Protocol. It handles 1:1 encrypted sessions between devices.

#### Megolm (Group Encryption)

Megolm is designed for encrypted group messaging where there may be many recipients per message. Unlike pairwise encryption, each participant maintains their own outbound Megolm session.

**How Megolm works:**
1. Each participant generates a Megolm session with a ratchet and an Ed25519 signing key pair
2. The session key is distributed to all group members via Olm (1:1 encrypted) channels
3. Each message: the sender ratchets forward, derives AES-256 + HMAC-SHA-256 keys, encrypts the message, and signs it
4. Recipients use the shared session key to derive the same message keys and decrypt
5. The ratchet is forward-only: recipients who join later cannot decrypt earlier messages (unless explicitly given earlier session keys)

**Megolm vs Signal Sender Keys:**

| Aspect | Megolm (Matrix) | Sender Keys (Signal) |
|--------|-----------------|---------------------|
| Key distribution | Via Olm 1:1 sessions | Via Signal Protocol 1:1 sessions |
| Ratchet type | Hash-based (one-way) | Hash-based (one-way) |
| Forward secrecy | Within a session; new sessions for recovery | Within a session |
| Message signing | Ed25519 per sender | Per sender |
| Designed for | Large rooms (100s-1000s of users) | Small-medium groups |
| Session rotation | Periodic; on membership change | On membership change |

#### Known Vulnerabilities and Lessons Learned

Critical vulnerabilities were disclosed in Matrix's E2EE implementation (2022-2023), providing important lessons:

1. **SDK-level key forwarding bugs:** matrix-react-sdk incorrectly forwarded existing message keys to newly invited users, violating forward secrecy expectations [9]
2. **Olm library issues:** AES cache timing vulnerabilities; media decryptable to multiple valid plaintexts using different keys [10]
3. **Metadata leakage:** Olm and Megolm expose sender identity and device information with every message [11]
4. **User responsibility overload:** Protocol designs that require users to verify device keys lead to security failures when users skip verification [9]

**Lesson:** E2EE implementation is extremely error-prone. Even Matrix, a project dedicated to encrypted communication, had practically exploitable vulnerabilities discovered by academic researchers. Rolling your own E2EE is strongly discouraged.

### 2.3 E2E and Server-Side Features: The Fundamental Conflict

**Confidence: High** (5 sources)

E2EE creates a fundamental architectural tension with server-side features that are core to a Slack-like experience.

| Feature | With E2EE | Without E2EE (Server-Side Encryption) |
|---------|-----------|---------------------------------------|
| **Full-text search** | Not possible server-side; must search on client | Server indexes and searches all messages |
| **Link previews** | Must be generated client-side | Server fetches and caches previews |
| **Message editing history** | Complex; requires re-encryption of edit chain | Straightforward database operations |
| **Admin compliance/export** | Impossible without key escrow (defeats purpose) | Admin tools can export any data |
| **Content moderation** | Limited to user reporting + metadata analysis | Server can scan all content |
| **Notifications with preview** | Server cannot generate preview text | Server generates rich notifications |
| **Bot integrations** | Bot must be a participant with keys | Bots access messages via API |
| **Message threading** | Works but server cannot index/organize threads | Full server-side thread management |

#### Approaches to the Conflict

**1. Message Franking (Metadata-Based Moderation):**
A cryptographic technique where the sender commits to the message content. If a recipient reports a message, the server can verify the sender actually sent it, without the server having prior access to content. Used by Facebook Messenger [12].

**2. Client-Side Scanning:**
Content analysis happens on the device before encryption. Controversial (Apple's abandoned CSAM scanning proposal). Undermines the privacy guarantee of E2EE [12].

**3. Homomorphic Encryption:**
Theoretically allows computation on encrypted data (e.g., spam detection). Practically too slow for real-time messaging by orders of magnitude [12].

**4. Hybrid Model (Recommended for Slack-like apps):**
- Standard channels: server-side encryption (full feature set)
- Optional "secure channels": E2EE with reduced feature set (no search, no previews, no bots)
- User chooses the trade-off per channel

### 2.4 What Signal, WhatsApp, Slack, and Matrix Chose (and Why)

**Confidence: High** (6 sources)

| Platform | Encryption Model | Why |
|----------|-----------------|-----|
| **Signal** | Full E2EE (Signal Protocol) for all messages | Privacy is the product. No server-side features that require message access. Minimal metadata collection. Open-source. [13] |
| **WhatsApp** | Full E2EE (Signal Protocol v4.3) for all messages | Consumer privacy expectation. Meta collects metadata but not content. Closed-source client. [14] |
| **Slack** | Server-side encryption (AES-256, FIPS 140-2); TLS in transit; optional EKM for enterprise | Enterprise features require server-side access: search, compliance, admin tools, integrations. EKM gives enterprises control of encryption keys without E2EE. [15][16] |
| **Matrix/Element** | E2EE via Olm/Megolm for encrypted rooms; optional per-room | Decentralized protocol; servers are untrusted by design. E2EE is optional per room to support both use cases. [17] |
| **Telegram** | Server-client encryption by default; optional "Secret Chats" with E2EE (MTProto) | Cloud sync and multi-device access prioritized. Secret Chats are device-specific. Custom protocol (criticized by cryptographers). |
| **Microsoft Teams** | Server-side encryption; E2EE available for 1:1 calls only | Enterprise features (compliance, DLP, eDiscovery) require server access. |

**Key insight:** Every platform that prioritizes enterprise/workplace features (Slack, Teams, Telegram's default) uses server-side encryption. Every platform that prioritizes privacy above all else (Signal, WhatsApp content) uses E2EE. Matrix offers both as a per-room choice. **For a Slack-like application, the Slack/Teams model is architecturally appropriate.**

### 2.5 E2E in Web Apps (WebSocket/LiveView) vs Native Clients

**Confidence: Medium** (4 sources)

Implementing E2EE in a web application (as opposed to a native mobile/desktop app) introduces additional challenges:

#### Browser Key Storage

The Web Crypto API (`SubtleCrypto`) provides cryptographic primitives in the browser, and `CryptoKey` objects can be stored in IndexedDB using the structured clone algorithm.

**Critical limitations:**
- IndexedDB is accessible via browser developer tools; stored data is not encrypted at rest on the device [18]
- There is no secure enclave or hardware-backed key storage available to web applications (unlike iOS Keychain or Android Keystore)
- Browser extensions can access IndexedDB data
- A compromised browser or XSS vulnerability exposes all stored keys
- The Web Crypto API documentation explicitly warns: "secure key management and overall security system design are extremely hard to get right" [18]

#### URL Fragment Key Sharing (Excalidraw Pattern)

Excalidraw pioneered a practical pattern for browser-based E2EE: placing the encryption key in the URL fragment (after `#`), which is never sent to the server but is accessible to client-side JavaScript [19].

**Applicability to chat:** Limited. This works for document sharing (share a link = share access) but not for ongoing chat sessions where keys must evolve and multiple participants need key management.

#### LiveView-Specific Challenges

Phoenix LiveView renders HTML on the server and sends diffs over WebSocket. This is fundamentally incompatible with E2EE because:
1. The server must have access to message content to render it
2. LiveView's server-side rendering model means encrypted messages would need to be decrypted on the server before rendering
3. A client-side JavaScript hook could decrypt messages, but this breaks LiveView's rendering model and requires significant client-side logic

**Assessment:** True E2EE in a LiveView-based chat would require a hybrid architecture where message content is handled by client-side JavaScript (React, vanilla JS) while LiveView manages the chrome/UI. This significantly increases architectural complexity.

---

## 3. Transport Security

### 3.1 TLS 1.3 for WebSocket Connections

**Confidence: High** (4 sources)

TLS 1.3 is the current best practice for encrypting all data in transit. Phoenix/Bandit supports TLS 1.3 since Erlang/OTP 22.2.3+.

#### Phoenix/Bandit TLS Configuration

```elixir
# config/prod.exs (or runtime.exs)
config :slackex, SlackexWeb.Endpoint,
  https: [
    port: 443,
    cipher_suite: :strong,
    certfile: System.get_env("SSL_CERT_PATH"),
    keyfile: System.get_env("SSL_KEY_PATH"),
    versions: [:"tlsv1.3", :"tlsv1.2"],
    # TLS 1.3 ciphers (automatically selected with :strong cipher_suite)
    ciphers: [
      ~c"TLS_AES_256_GCM_SHA384",
      ~c"TLS_CHACHA20_POLY1305_SHA256",
      ~c"TLS_AES_128_GCM_SHA256"
    ],
    honor_cipher_order: true,
    secure_renegotiate: true,
    reuse_sessions: true
  ]
```

**Key points:**
- Bandit (Slackex's HTTP server) handles TLS termination and passes options through to Erlang's `:ssl` module [20]
- The `cipher_suite: :strong` option in Plug.SSL selects secure defaults
- WebSocket connections (`wss://`) automatically use the same TLS configuration as HTTPS
- TLS 1.3 eliminates the 0-RTT handshake vulnerability present in TLS 1.2's session resumption and removes support for weak cipher suites

#### TLS 1.3 Improvements Over 1.2

| Feature | TLS 1.2 | TLS 1.3 |
|---------|---------|---------|
| Handshake round trips | 2 RTT | 1 RTT (0-RTT optional) |
| Cipher suites | Many (including weak ones) | Only AEAD ciphers |
| Forward secrecy | Optional (depends on cipher) | Mandatory |
| Key exchange | RSA or DHE | DHE or ECDHE only |
| Compression | Supported (CRIME vulnerability) | Removed |

### 3.2 Certificate Pinning Considerations

**Confidence: High** (4 sources)

Certificate pinning adds an additional verification layer by restricting which TLS certificates the client accepts. However, industry consensus has shifted against it.

**Current industry position:**
- Google explicitly recommends against SSL pinning in Android security best practices [21]
- The HTTP Public-Key-Pins (HPKP) header has been deprecated by all major browsers [21]
- Certificate Transparency (CT) logs provide an alternative mechanism for detecting unauthorized certificates

**Recommendation for Slackex:** Do NOT implement certificate pinning. It creates operational fragility (certificate rotation breaks clients), provides marginal security benefit over Certificate Transparency, and is actively discouraged by the industry. Rely on TLS 1.3 with a reputable CA and Certificate Transparency monitoring.

### 3.3 Phoenix/Bandit Security Best Practices

**Confidence: High** (4 sources)

| Practice | Implementation | Status in Slackex |
|----------|---------------|-------------------|
| Force HTTPS | `Plug.SSL` in endpoint or load balancer redirect | Verify in production config |
| HSTS header | `Plug.SSL` with `hsts: true` | Verify |
| Secure WebSocket (wss://) | Automatic when HTTPS is configured | Automatic |
| CSRF protection | Phoenix includes CSRF tokens for forms; LiveView validates `_csrf_token` on mount | Built-in |
| Origin checking | Phoenix checks `check_origin` on WebSocket connections | Built-in (verify config) |
| Content Security Policy | Configure CSP headers to prevent XSS | Manual configuration needed |
| Secure cookies | `secure: true`, `http_only: true`, `same_site: "Lax"` | Verify in endpoint config |

---

## 4. Data Protection Architecture Patterns

### 4.1 Zero-Knowledge Architecture vs Trust-the-Server

**Confidence: High** (4 sources)

| Aspect | Zero-Knowledge | Trust-the-Server |
|--------|---------------|-----------------|
| **Who can read data** | Only the user (client-side encryption) | Server operators and authorized users |
| **Server role** | Stores encrypted blobs; cannot read content | Stores, indexes, processes, and serves content |
| **Feature richness** | Limited (no server-side search, processing) | Full (search, moderation, analytics, integrations) |
| **Breach impact** | Encrypted data only; no plaintext exposure | Potential plaintext exposure |
| **Compliance** | Strong privacy but challenging auditability | Standard compliance tools and audit trails |
| **Key management** | User-managed (lost key = lost data) | Server-managed (recovery possible) |
| **Examples** | Signal, Proton Mail, Excalidraw | Slack, Microsoft Teams, Google Workspace |

**Assessment for Slackex:** A trust-the-server model with strong server-side encryption is appropriate. The application already relies on server-side rendering (LiveView), server-side search, and server-mediated features. Zero-knowledge would require a fundamental architectural redesign.

### 4.2 Envelope Encryption Pattern (Detailed)

**Confidence: High** (5 sources)

See Section 1.3 for the full envelope encryption description. Key architectural decisions for Slackex:

**DEK Granularity Options:**

| Granularity | Pros | Cons | Recommendation |
|-------------|------|------|----------------|
| Per-message | Maximum isolation; compromise of one key affects one message | High KMS call volume; latency per message | Not recommended (too expensive) |
| Per-channel | Good isolation; natural security boundary | Key rotation requires re-encrypting channel history | Recommended for most deployments |
| Per-user | Simple user-level erasure (delete key = erase user) | Large blast radius on key compromise | Good for PII; combine with per-channel for messages |
| Per-workspace | Simplest management | Largest blast radius | Minimum viable option |

**Recommended approach for Slackex:**
- Per-user DEK for user PII fields (email, name, phone)
- Per-channel DEK for message content
- Single KEK per workspace in cloud KMS, with automatic rotation

### 4.3 Field-Level vs Row-Level vs Database-Level Encryption

**Confidence: High** (5 sources)

| Level | Scope | Queryability | Performance | Complexity | Use Case |
|-------|-------|-------------|-------------|------------|----------|
| **Field-level** (Cloak.Ecto) | Individual columns | Only via hash proxies | Per-field overhead | Low-Medium | Selective PII/content encryption |
| **Row-level** | Entire rows | None on encrypted data | Per-row overhead | Medium | All-or-nothing row encryption |
| **Table-level** (pg_tde) | Entire tables | Full (transparent) | Minimal (hardware-accelerated) | Low | Compliance checkbox; protects at-rest storage |
| **Database-level** (disk encryption) | Entire database | Full (transparent) | Minimal | Very Low | Baseline defense-in-depth |

**Recommended layering for Slackex:**
1. Database-level: Disk encryption (managed database services do this by default)
2. Table-level: Consider pg_tde if using Percona PostgreSQL
3. Field-level: Cloak.Ecto for message bodies, user PII, and tokens

### 4.4 Searchable Encryption Techniques

**Confidence: Low** (3 sources, primarily academic)

Searchable encryption aims to allow queries on encrypted data. The main approaches:

#### Symmetric Searchable Encryption (SSE)

SSE builds encrypted indexes that allow keyword search without decrypting the data. Academic research is extensive, but practical deployment remains challenging.

**Current state:**
- Theoretical designs often fail to be efficient in practice due to I/O access patterns [22]
- Leakage is inherent: access patterns, search patterns, and result sizes reveal information
- ORAM-based mitigations for leakage add significant overhead [22]
- Dynamic updates (adding/deleting messages) remain an open challenge [22]

#### Order-Preserving Encryption (OPE)

OPE preserves the ordering of plaintext in ciphertext, enabling range queries on encrypted data.

**Critical problems:**
- Cannot achieve standard security (IND-CPA) because ordering is inherently leaked [23]
- Frequency attacks can recover over 90% of plaintext from ciphertext alone [23]
- Cumulative and sorting attacks are well-documented [23]
- **Not recommended for any security-sensitive application**

#### Deterministic Encryption (for Equality Searches)

Cloak.Ecto's SHA256/HMAC hash approach is a form of deterministic encryption that enables equality searches.

**Trade-offs:**
- Enables exact-match lookups (e.g., find user by email hash)
- Does NOT support substring search, LIKE queries, or full-text search
- Hash collisions are theoretically possible but practically negligible with SHA-256
- Reveals whether two values are equal (frequency analysis possible on low-cardinality fields)

**Assessment:** For Slackex, the practical approach is:
- Use Cloak.Ecto's SHA256/HMAC hashes for equality searches on encrypted PII (e.g., find user by email)
- Accept that full-text search over encrypted message content is not feasible with current technology
- If full-text search is needed (it almost certainly is for a Slack-like app), search on the server with server-side encryption rather than E2EE

### 4.5 Data Retention and Secure Deletion

**Confidence: High** (4 sources)

#### Cryptographic Erasure

Instead of physically deleting data from every database table, backup, and replica, cryptographic erasure deletes the encryption key, rendering the encrypted data permanently unrecoverable.

**Requirements for effective cryptographic erasure:**
1. Strong encryption (AES-256-GCM or equivalent)
2. Unique keys per erasure scope (per-user for GDPR right to erasure)
3. Secure key deletion (zeroing memory, secure deletion from KMS)
4. No copies of the key in logs, backups, or caches
5. Documentation of the erasure process for compliance audits

**GDPR Right to Erasure workflow with envelope encryption:**
1. User requests account deletion
2. Application identifies the user's per-user DEK
3. Application deletes the DEK from the KMS (and all backups of the DEK)
4. All data encrypted with that DEK becomes permanently inaccessible
5. Optionally: physically delete the ciphertext rows for storage reclamation
6. Log the erasure event for compliance audit trail

**NIST SP 800-88 guidelines** define three levels of media sanitization: Clear (logical overwrite), Purge (physical/cryptographic methods), and Destroy (physical destruction). Cryptographic erasure qualifies as a Purge-level technique when properly implemented [24].

---

## 5. Elixir/Phoenix Ecosystem

### 5.1 Cloak and Cloak.Ecto

**Confidence: High** (4 sources)

See Section 1.2 for detailed Cloak.Ecto documentation. Key ecosystem details:

| Package | Version | Hex Downloads | Status |
|---------|---------|---------------|--------|
| `cloak` | 1.1.4 | ~3.5M | Stable; maintained |
| `cloak_ecto` | 1.3.0 | ~2.8M | Stable; maintained |

**Integration with Slackex's stack:**
- Compatible with Ecto 3.x (Slackex uses `ecto_sql ~> 3.13`)
- Uses Erlang's `:crypto` module (built into OTP; no additional dependencies)
- Works with PostgreSQL binary columns
- Compatible with Phoenix 1.8 and LiveView 1.1

### 5.2 Erlang :crypto Module

**Confidence: High** (4 sources)

The `:crypto` module is Erlang/OTP's built-in interface to OpenSSL, providing low-level cryptographic primitives. It is the foundation that Cloak and ExCrypto build upon.

**Capabilities:**
- Symmetric encryption: AES (CBC, CTR, GCM, CCM), ChaCha20-Poly1305, Blowfish, DES/3DES
- Hash functions: SHA-1, SHA-2 (256/384/512), SHA-3, MD5, BLAKE2
- MAC: HMAC, CMAC, Poly1305
- Public key: RSA, DSA, ECDSA, EdDSA (Ed25519, Ed448), DH, ECDH
- Random number generation: `strong_rand_bytes/1` (cryptographically secure)
- Key derivation: HKDF, PBKDF2

**For Slackex, the relevant functions are:**
```elixir
# AES-256-GCM encryption (what Cloak uses internally)
{ciphertext, tag} = :crypto.crypto_one_time_aead(
  :aes_256_gcm, key, iv, plaintext, aad, true
)

# Cryptographically secure random bytes (for IVs, keys)
iv = :crypto.strong_rand_bytes(16)
key = :crypto.strong_rand_bytes(32)  # 256-bit key

# HMAC for searchable hash columns
:crypto.mac(:hmac, :sha256, secret, data)
```

### 5.3 ExCrypto

**Confidence: Medium** (3 sources)

ExCrypto is an Elixir wrapper around `:crypto` that provides a higher-level API with sensible defaults.

| Feature | ExCrypto | Raw :crypto | Cloak |
|---------|----------|-------------|-------|
| API level | Mid-level convenience | Low-level primitives | High-level Ecto integration |
| Automatic IV | Yes | No (manual) | Yes |
| Key generation helpers | Yes (by type/format) | No | Via vault config |
| Ecto integration | No | No | Yes (Cloak.Ecto) |
| Payload encoding | Yes (Base64 URL) | No | Yes (binary) |
| Maintenance | Low activity | Part of OTP (always maintained) | Active |

**Assessment:** For Slackex, Cloak.Ecto is the recommended choice because it integrates directly with Ecto schemas. ExCrypto or raw `:crypto` would be used only for custom encryption scenarios outside of Ecto (e.g., encrypting data before sending to Redis, encrypting file attachments).

### 5.4 Existing Elixir Libraries for E2E Encryption

**Confidence: Low** (limited sources; see Knowledge Gaps)

There is no mature, production-ready Elixir library implementing the Signal Protocol or Olm/Megolm. The Elixir ecosystem's E2EE options are:

| Library/Approach | Status | Notes |
|-----------------|--------|-------|
| Raw `:crypto` + `:public_key` | Available | Build your own; not recommended for E2EE |
| `ex_crypto` | Available | Convenience wrapper; not an E2EE protocol |
| JOSE (JSON Object Signing and Encryption) | Available (`jose` package in Slackex deps) | JWE/JWS; for token encryption, not message E2EE |
| NIF wrapper around libsignal-protocol-c | Theoretically possible | No existing package; significant effort |
| NIF wrapper around vodozemac (Matrix's Rust crypto) | Theoretically possible | No existing package; significant effort |

**Assessment:** If E2EE were required, the most practical path would be implementing it client-side in JavaScript using existing JS libraries (libsignal-protocol-javascript, vodozemac-js) and using Phoenix channels/WebSocket purely as an encrypted message transport. The Elixir server would never see plaintext.

### 5.5 Phoenix Channel/LiveView Security Considerations

**Confidence: High** (4 sources)

Phoenix LiveView's security model has specific characteristics relevant to a chat application:

#### Authentication and Authorization

LiveView enforces a dual-check model [25]:
1. **HTTP phase:** Plug pipeline validates session/cookies during initial page load
2. **WebSocket phase:** `mount/3` callback must re-validate authentication
3. **Event phase:** Every `handle_event` must verify authorization

```elixir
# In LiveView mount
def mount(_params, session, socket) do
  case Accounts.get_user_by_session_token(session["user_token"]) do
    nil -> {:ok, redirect(socket, to: "/login")}
    user -> {:ok, assign(socket, current_user: user)}
  end
end

# In handle_event - ALWAYS verify permissions
def handle_event("send_message", params, socket) do
  if authorized?(socket.assigns.current_user, :send_message, channel) do
    # proceed
  else
    {:noreply, put_flash(socket, :error, "Not authorized")}
  end
end
```

#### WebSocket-Specific Concerns

- **SameSite cookies do not apply to WebSockets:** Browsers send all cookies regardless of SameSite attribute when initiating WebSocket connections [25]
- **Origin checking:** Phoenix's `check_origin` configuration validates that WebSocket connections originate from allowed domains
- **CSRF in LiveView:** The `_csrf_token` parameter must be explicitly validated during socket connection
- **Session disconnection:** Use `live_socket_id` to broadcast disconnect messages when a user logs out or access is revoked

#### Content Security Policy for LiveView

LiveView's WebSocket connections require careful CSP configuration:
```
connect-src 'self' wss://yourdomain.com;
```

---

## 6. Compliance and Regulatory Context

### 6.1 GDPR Implications for Encrypted Messaging

**Confidence: High** (5 sources)

#### Is Encrypted Data Still Personal Data?

Under GDPR, encrypted data is generally still considered personal data if the data controller possesses (or can obtain) the decryption key. The IAPP (International Association of Privacy Professionals) notes this is context-dependent: if the encryption is irreversible to the controller, it may not be personal data [26].

**For Slackex:** Since the application manages the encryption keys (server-side encryption model), encrypted message data remains personal data under GDPR.

#### Encryption as a Safeguard

GDPR does not mandate encryption, but it is strongly recommended as a technical safeguard:
- **Article 32:** Requires "appropriate technical and organisational measures" including "encryption of personal data" as an explicit example
- **Article 34:** If encrypted data is breached but the key is not compromised, the breach notification to individuals may not be required (significant cost/reputation savings)
- **Recital 83:** Explicitly mentions encryption as a means to protect personal data

#### Right to Erasure (Article 17)

Organizations must erase personal data "without undue delay" when grounds exist. Cryptographic erasure (deleting the encryption key) is an accepted method when:
1. The encryption is strong (AES-256 or equivalent)
2. The key is the sole means of decryption
3. Key deletion is verifiable and auditable
4. The process is documented in privacy impact assessments

**Interpretation:** Per-user encryption keys with envelope encryption provide the cleanest GDPR erasure path. Deleting a user's DEK renders all their encrypted data permanently inaccessible without modifying every database table [27][28].

### 6.2 SOC 2 Encryption Requirements

**Confidence: High** (4 sources)

SOC 2 does not prescribe specific encryption algorithms or methods. Instead, under the Trust Services Criteria (TSC), particularly CC6 (Logical and Physical Access):

- **CC6.1:** The entity implements logical access security software, infrastructure, and architectures to protect information assets
- **CC6.7:** Restrict transmission, movement, and removal of information to authorized users and processes

**Practical requirements:**
- Encryption of data at rest (database, file storage, backups)
- Encryption of data in transit (TLS for all connections)
- Key management procedures documented and followed
- Access controls on encryption keys
- Regular key rotation

**What satisfies SOC 2:** TLS 1.2+ for transit + AES-256 for at-rest encryption + documented key management procedures. E2EE is not required [29][30].

### 6.3 ISO 27001 Encryption Requirements

**Confidence: High** (4 sources)

ISO 27001:2022 Annex A Control 8.24 (Use of Cryptography) mandates:

1. **Cryptographic policy:** Define rules for effective use of cryptography
2. **Key management:** Address the full key lifecycle (generation, storage, distribution, rotation, revocation, destruction)
3. **Algorithm selection:** Based on sensitivity and risk assessment (AES-256, RSA-4096 typical recommendations)
4. **Scope:** Data at rest AND data in transit
5. **Governance:** Focus on outcomes and governance, not specific algorithm mandates

**What satisfies ISO 27001:** A documented cryptographic policy + TLS 1.3 for transit + AES-256-GCM for at-rest + key lifecycle management + regular reviews. E2EE is not required [31][32].

### 6.4 Lawful Interception Considerations

**Confidence: Medium** (3 sources)

#### CALEA (U.S.)

The Communications Assistance for Law Enforcement Act applies to telecommunications carriers and VoIP providers. It generally does NOT apply to "information services" (websites, email, social media, chat applications) [33].

**Key provision:** CALEA does not require carriers to decrypt communications if the carrier does not possess the decryption key. This is the "going dark" provision that law enforcement frequently criticizes.

**For Slackex:**
- As a web-based chat application, Slackex is likely classified as an "information service" and exempt from CALEA
- However, Slackex must still respond to valid court orders (subpoenas, warrants) for data it possesses
- With server-side encryption (where Slackex holds keys), response to lawful orders means decrypting and providing requested data
- With E2EE (where Slackex does not hold keys), Slackex could only provide encrypted ciphertext and metadata

#### International Considerations

- **EU:** Proposed regulations around E2EE scanning ("chat control") remain contentious and are not finalized
- **UK:** The Online Safety Act 2023 includes provisions that could require scanning of E2EE content, though technical implementation remains undefined
- **Australia:** The Telecommunications and Other Legislation Amendment (Assistance and Access) Act 2018 can compel companies to provide technical assistance for law enforcement access

**Assessment:** For a Slack-like enterprise chat tool, server-side encryption provides a clear compliance path for lawful interception requirements. E2EE would create legal uncertainty in multiple jurisdictions.

---

## 7. Practical Recommendations

### 7.1 Tiered Implementation Approach

#### Phase 1: Foundation (Implement First)

| Action | Effort | Security Benefit | Tools |
|--------|--------|-----------------|-------|
| TLS 1.3 for all connections | Low | High -- protects all data in transit | Phoenix/Bandit config; Let's Encrypt or managed certs |
| Cloak.Ecto for user PII | Low-Medium | High -- protects email, name, phone at rest | `cloak` + `cloak_ecto` hex packages |
| Cloak.Ecto for message bodies | Medium | High -- protects core content at rest | Same packages; migration to encrypt existing data |
| HMAC hash columns for searchable PII | Low | Medium -- enables search without exposing plaintext | `Cloak.Ecto.HMAC` |
| Secure cookie configuration | Low | Medium -- prevents session attacks | Phoenix endpoint config |
| CSP headers | Low | Medium -- prevents XSS | Plug middleware |

**Estimated effort:** 1-2 weeks for a developer familiar with the codebase.

#### Phase 2: Hardened Key Management (Near-Term)

| Action | Effort | Security Benefit | Tools |
|--------|--------|-----------------|-------|
| Envelope encryption with cloud KMS | Medium | High -- separates key hierarchy; key never in application memory | AWS KMS / GCP KMS + ExAws or equivalent |
| Per-user DEK for PII | Medium | High -- enables cryptographic erasure for GDPR | Application-level key management |
| Per-channel DEK for messages | Medium | Medium -- limits blast radius of key compromise | Application-level key management |
| Key rotation automation | Medium | Medium -- limits exposure window | `mix cloak.migrate` + Oban scheduled job |
| Secure deletion workflow | Medium | Medium -- GDPR compliance | Application logic + KMS key deletion |

**Estimated effort:** 2-4 weeks.

#### Phase 3: Advanced (If Needed)

| Action | Effort | Security Benefit | Tools |
|--------|--------|-----------------|-------|
| E2EE for optional "secure channels" | Very High | High (for those channels) | Client-side JS crypto (libsignal or similar) |
| Hardware-backed key storage (HSM) | High | Medium-High -- FIPS 140-2 Level 3 | Cloud HSM or dedicated hardware |
| Audit logging of all key access | Medium | Medium -- compliance and forensics | Application logging + SIEM integration |
| Database TDE (pg_tde) | Medium | Medium -- additional layer of defense | Percona Distribution for PostgreSQL |

**Estimated effort:** 4-12 weeks depending on scope.

### 7.2 Cost/Complexity vs Security Benefit Analysis

```
                        HIGH SECURITY BENEFIT
                              |
         Cloak.Ecto PII  *   |   * TLS 1.3
                              |
         Cloak.Ecto msgs *   |   * Envelope Encryption + KMS
                              |
    Cryptographic erasure *   |
                              |
    ---- LOW COMPLEXITY ------+------ HIGH COMPLEXITY ----
                              |
              pg_tde *        |   * Key rotation automation
                              |
        Secure cookies *      |   * Per-channel DEKs
                              |
              CSP *           |   * E2EE secure channels
                              |
                              |                   * Full E2EE
                              |
                        LOW SECURITY BENEFIT
```

### 7.3 Slack-Like App vs Signal-Like App

| Decision Factor | Slack-Like (Slackex) | Signal-Like |
|----------------|---------------------|-------------|
| **Primary value** | Collaboration, searchability, integrations | Privacy above all else |
| **Encryption model** | Server-side encryption (Cloak.Ecto + KMS) | End-to-end encryption (Signal Protocol) |
| **Search** | Full-text server-side search | Client-side search only |
| **Compliance** | Straightforward (server has access for legal requests) | Complex (cannot provide plaintext) |
| **Moderation** | Server can scan/moderate content | Limited to user reports |
| **Integrations/bots** | Full API access to messages | Bots must be E2EE participants |
| **Key management** | Server manages keys (user recovery possible) | User manages keys (lost = lost forever) |
| **Implementation effort** | Weeks (Cloak.Ecto + KMS) | Months (custom crypto + client-side architecture) |
| **Architecture fit** | LiveView server-rendering model | Requires heavy client-side JS |

---

## 8. Knowledge Gaps

The following areas were researched but insufficient evidence was found to make strong claims:

### 8.1 Cloak.Ecto Performance Benchmarks

**What was searched:** "Cloak Ecto performance benchmarks encryption overhead PostgreSQL"
**What was found:** No published benchmarks comparing encrypted vs unencrypted Ecto operations. General PostgreSQL encryption research suggests overhead but no Cloak-specific measurements.
**Impact:** Unable to provide concrete latency/throughput numbers for the encryption overhead. The recommendation is to benchmark in the specific Slackex environment.

### 8.2 Elixir E2EE Libraries

**What was searched:** "Elixir end-to-end encryption library Signal Protocol Olm implementation"
**What was found:** No mature Elixir library implementing Signal Protocol, Olm, Megolm, or any E2EE messaging protocol. The ecosystem relies on `:crypto` primitives and Cloak for at-rest encryption.
**Impact:** If E2EE is required, it must be implemented client-side in JavaScript or via NIFs wrapping C/Rust libraries. This is a significant architectural decision.

### 8.3 Searchable Encryption in Production

**What was searched:** "Searchable symmetric encryption production deployment real-world messaging"
**What was found:** Extensive academic literature but no documented production deployments in messaging applications. CipherDB and similar commercial offerings exist but no case studies for chat-scale workloads.
**Impact:** Searchable encryption cannot be recommended as a practical solution for Slackex. The gap between academic research and production-ready implementations remains wide.

### 8.4 Phoenix LiveView + Client-Side E2EE Integration Patterns

**What was searched:** "Phoenix LiveView client-side encryption JavaScript hooks E2EE integration"
**What was found:** No documented patterns for integrating client-side E2EE with LiveView's server-rendering model. The Elixir Forum thread on E2EE with Phoenix is from 2016 and predates LiveView entirely.
**Impact:** If E2EE is pursued, the integration architecture would need to be designed from scratch, likely using LiveView hooks to bridge server-rendered UI with client-side crypto.

### 8.5 Quantified Performance Impact of Envelope Encryption with KMS

**What was searched:** "KMS API call latency impact on message send performance real-time chat"
**What was found:** AWS KMS documentation mentions sub-100ms latency for API calls, but no benchmarks for high-throughput chat scenarios with per-channel DEK caching strategies.
**Impact:** The recommendation to cache DEKs in memory (with rotation) is based on general architecture principles rather than measured performance data specific to Elixir applications.

---

## 9. Sources

### Tier 1: Official Documentation and Standards

[1] PostgreSQL Documentation 18: Encryption Options
https://www.postgresql.org/docs/current/encryption-options.html

[2] Crunchy Data: "Data Encryption in Postgres: A Guidebook"
https://www.crunchydata.com/blog/data-encryption-in-postgres-a-guidebook

[3] EDB: "What is Transparent Data Encryption (TDE)? Benefits, Types, and Best Practices"
https://www.enterprisedb.com/blog/everything-need-know-postgres-data-encryption

[4] Percona: pg_tde Documentation
https://docs.percona.com/pg-tde/

[5] Percona: "Protect Your PostgreSQL Database with pg_tde"
https://www.percona.com/blog/protect-your-postgresql-database-with-pg_tde-safe-and-secure/

[6] Google Cloud: Envelope Encryption Documentation
https://docs.cloud.google.com/kms/docs/envelope-encryption

[7] AWS: KMS Cryptography Essentials
https://docs.aws.amazon.com/kms/latest/developerguide/kms-cryptography.html

[8] Fortanix: "Cloud HSM vs KMS: What's Best for Enterprise Security?"
https://www.fortanix.com/blog/cloud-hsm-vs-kms-which-is-right-for-your-enterprise-data-security-strategy

### Tier 2: Security Research and Protocol Specifications

[9] Matrix.org: "Upgrade now to address E2EE vulnerabilities in matrix-js-sdk"
https://matrix.org/blog/2022/09/28/upgrade-now-to-address-encryption-vulns-in-matrix-sdks-and-clients/

[10] Soatok: "Security Issues in Matrix's Olm Library" (2024)
https://soatok.blog/2024/08/14/security-issues-in-matrixs-olm-library/

[11] Wire: "Why Olm and Megolm Fail EU Data Privacy Standards"
https://wire.com/en/blog/olm-megolm-eu-data-privacy-risk

[12] Center for Democracy and Technology: "Outside Looking In: Approaches to Content Moderation in End-to-End Encrypted Systems"
https://cdt.org/insights/outside-looking-in-approaches-to-content-moderation-in-end-to-end-encrypted-systems/

[13] Signal: Double Ratchet Algorithm Specification
https://signal.org/docs/specifications/doubleratchet/

[14] WhatsApp: "About end-to-end encryption"
https://faq.whatsapp.com/820124435853543

[15] Slack: "Security at Slack: How Slack Protects Your Data"
https://slack.com/blog/collaboration/security-at-slack-how-slack-protects-your-data

[16] Slack Engineering: "Engineering Dive into Slack Enterprise Key Management"
https://slack.engineering/engineering-dive-into-slack-enterprise-key-management/

[17] Matrix.org: End-to-End Encryption Implementation Guide
https://matrix.org/docs/matrix-concepts/end-to-end-encryption/

[18] MDN: Web Crypto API / SubtleCrypto
https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto

[19] Excalidraw Blog: "End-to-End Encryption in the Browser"
https://plus.excalidraw.com/blog/end-to-end-encryption

### Tier 3: Elixir/Phoenix Ecosystem

[20] Phoenix Documentation: "Using SSL"
https://hexdocs.pm/phoenix/using_ssl.html

[21] OWASP: Certificate and Public Key Pinning
https://owasp.org/www-community/controls/Certificate_and_Public_Key_Pinning

[22] ACM Computing Surveys: "Searchable Symmetric Encryption: Designs and Challenges"
https://dl.acm.org/doi/10.1145/3064005

[23] IACR ePrint: "Frequency-revealing attacks against Frequency-hiding Order-preserving Encryption"
https://eprint.iacr.org/2023/1122

[24] NIST SP 800-88: Guidelines for Media Sanitization
https://csrc.nist.gov/pubs/sp/800/88/r1/final

[25] Phoenix LiveView: Security Considerations
https://hexdocs.pm/phoenix_live_view/security-model.html

[26] IAPP: "Is encrypted data personal data under the GDPR?"
https://iapp.org/news/a/is-encrypted-data-personal-data-under-the-gdpr

[27] GDPR-info.eu: Encryption
https://gdpr-info.eu/issues/encryption/

[28] Townsend Security: "GDPR, Right of Erasure, and Encryption Key Management"
https://info.townsendsecurity.com/gdpr-right-erasure-encryption-key-management

[29] TrustNet: "SOC 2 Encryption Requirements"
https://trustnetinc.com/resources/does-soc-2-require-data-to-be-encrypted-2/

[30] Copla: "SOC 2 encryption requirements: Key guidelines for data security"
https://copla.com/blog/compliance-regulations/soc-2-encryption-requirements-key-guidelines-for-data-security/

[31] ISMS.online: "ISO 27001:2022 Annex A Control 8.24"
https://www.isms.online/iso-27001/annex-a-2022/8-24-use-of-cryptography-2022/

[32] HighTable: "ISO 27001:2022 Annex A 8.24 Use of Cryptography"
https://hightable.io/iso27001-annex-a-8-24-use-of-cryptography/

[33] FCC: Communications Assistance for Law Enforcement Act
https://www.fcc.gov/calea

### Tier 4: Elixir Libraries and Tools

[34] Cloak (Hex): Elixir encryption library designed for Ecto
https://github.com/danielberkompas/cloak

[35] Cloak.Ecto (HexDocs): Encrypted fields for Ecto
https://hexdocs.pm/cloak_ecto/readme.html

[36] ExCrypto (HexDocs): Wrapper around Erlang crypto module
https://hexdocs.pm/ex_crypto/ExCrypto.html

[37] Elixir Forum: "Security: HTTPS, WSS, PFS and E2EE with Phoenix framework"
https://elixirforum.com/t/security-https-wss-pfs-and-e2ee-with-phoenix-framework/2091

[38] Elixir Forum: "Using TLS 1.3 with Phoenix"
https://elixirforum.com/t/using-tls-1-3-with-phoenix/28490

[39] Signal: X3DH Key Agreement Protocol Specification
https://signal.org/docs/specifications/x3dh/

[40] Georgetown Law Technology Review: "Content Moderation on End-to-End Encrypted Systems"
https://georgetownlawtechreview.org/content-moderation-on-end-to-end-encrypted-systems-a-legal-analysis/GLTR-01-2024/

[41] Cossack Labs: "PII Encryption Requirements Cheatsheet"
https://www.cossacklabs.com/blog/pii-encryption-requirements-cheatsheet/

[42] Encryption Consulting: "PII Data Encryption"
https://www.encryptionconsulting.com/pii-data-encryption-protecting-sensitive-customer-data/

[43] Matrix Specification v1.17: Olm and Megolm
https://spec.matrix.org/v1.17/olm-megolm/

[44] IACR ePrint: "Practically-exploitable Cryptographic Vulnerabilities in Matrix" (2023)
https://eprint.iacr.org/2023/485

---

## Addendum A: Native Mobile Client Impact on E2E Assessment

**Date:** 2026-02-27
**Context:** Slackex is currently web-only (Phoenix LiveView). Future work considers native iOS/Android clients. This addendum evaluates how native clients affect the E2E encryption assessment while maintaining the primary product direction as a Slack/Discord/Teams-style collaboration app.

### Key Storage: The Biggest Shift

The research identified browser key storage as a critical E2E weakness (Section 2.5). Native platforms eliminate this limitation:

| Capability | Web (LiveView) | iOS Native | Android Native |
|------------|---------------|------------|----------------|
| Hardware-backed key storage | No | Yes (Secure Enclave / Keychain) | Yes (Keystore / StrongBox) |
| Key extraction resistance | Weak (IndexedDB) | Hardware-enforced | Hardware-enforced |
| Biometric-gated key access | Limited (WebAuthn) | Face ID / Touch ID | Fingerprint / Face Unlock |
| Background key management | Not possible | Yes (background fetch for pre-keys) | Yes (WorkManager) |
| Secure memory handling | No control | Yes (Data Protection API) | Yes (encrypted memory regions) |

### Rendering Model: LiveView Conflict Disappears

The fundamental incompatibility identified in Section 2.5 — LiveView must see plaintext to render HTML — does not apply to native clients. Native clients render locally, allowing the server to act as an encrypted message relay without access to plaintext. This is exactly how Signal and WhatsApp operate.

### Library Maturity: Production-Ready Options Exist

Unlike the Elixir ecosystem (Knowledge Gap 8.2), native platforms have mature E2E libraries:

- **libsignal-client** (Signal Foundation): Production-proven Rust library with official Swift and Kotlin bindings. Powers Signal and WhatsApp.
- **vodozemac** (Matrix): Rust implementation of Olm/Megolm with Swift and Kotlin bindings.

Both are actively maintained by dedicated security teams with regular audits.

### What Doesn't Change

The server-side feature trade-off (Section 2.3) remains identical regardless of client platform:

- E2E still prevents server-side full-text search, content moderation, link previews, admin compliance export, and server-mediated bot integrations
- For a Slack/Discord/Teams-style collaboration app, these features are core to the product value proposition
- The compliance assessment (Section 6) is unchanged: server-side encryption satisfies GDPR, SOC 2, and ISO 27001

### Hybrid Model: Viable With Native Clients

Native clients enable a Matrix-style per-channel encryption toggle:

| Channel Type | Encryption | Features | Client Support |
|-------------|-----------|----------|---------------|
| Standard | Server-side (Cloak.Ecto + KMS) | Full: search, moderation, bots, compliance, previews | Web + Native |
| Secure (opt-in) | E2E via libsignal-client | Reduced: no search, no previews, no bots | Native only |

The web client participates fully in standard channels. Secure channels would be native-only or offer degraded read-only access on web.

### Revised E2E Feasibility Matrix

| Scenario | E2E Feasibility | Recommendation |
|----------|----------------|---------------|
| Web-only (current) | Low | Server-side encryption only |
| Web + native clients | Medium | Hybrid model viable for native; web stays server-side |
| Native-only (hypothetical) | High | Full E2E architecturally natural if features allow |

### Recommendation

**No change to Phase 1-2 implementation priority.** Server-side encryption (Cloak.Ecto + TLS + envelope encryption with KMS) is the correct foundation regardless of client platform. This infrastructure serves both the current web app and future native clients.

When native client development begins, evaluate the hybrid per-channel E2E model as a Phase 3+ feature. The server-side encryption infrastructure built in Phase 1-2 supports both encryption models simultaneously.

E2E remains a product decision (collaboration features vs per-channel privacy), not a technical blocker — native clients remove the technical barriers identified in the main research.

---

*Research completed 2026-02-27. Addendum A added 2026-02-27. Total sources consulted: 44. Major claims cross-referenced across 3+ independent sources where possible. Knowledge gaps documented in Section 8.*
