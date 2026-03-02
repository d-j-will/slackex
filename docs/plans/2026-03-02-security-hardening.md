# Security Hardening Plan

**Date:** 2026-03-02
**Status:** Draft
**Audit source:** `docs/plans/2026-03-02-security-hardening.md` (this document)
**Deployment prerequisite:** Items in Phase 1 (CRITICAL/HIGH) should be deployed before any public-facing launch.

## Problem

A comprehensive security audit on 2026-03-02 identified 19 findings across authentication, sessions, input validation, cryptography, deployment, and infrastructure. The codebase has strong security fundamentals (Cloak encryption, JWT rotation with family invalidation, bcrypt, CSRF, Ecto parameterization) but is missing several standard hardening measures expected before production use scales.

## Design Principles

- **Defence in depth:** Each layer (app, proxy, network) should enforce its own security controls independently.
- **Fail closed:** Missing configuration (env vars, SSL certs) must raise at startup, never silently degrade.
- **Minimal blast radius:** Cookie theft, DB leak, or network interception should each be bounded by layer-specific mitigations.
- **Incremental rollout:** Fixes are ordered by severity and grouped into independently deployable phases.
- **No feature regression:** All changes are additive config or hardening — no user-facing behaviour changes.

## Phases

| Phase | Focus | Severity | Effort |
|-------|-------|----------|--------|
| 1 | Transport & Cookie Security | CRITICAL/HIGH | ~30 min |
| 2 | Authentication Hardening | HIGH | ~2 hours |
| 3 | Infrastructure & Headers | HIGH/MEDIUM | ~1 hour |
| 4 | Input Validation & Cleanup | MEDIUM/LOW | ~2 hours |
| 5 | Missing Auth Flows | HIGH | ~4 hours |

---

## Phase 1: Transport & Cookie Security

**Goal:** Ensure all traffic is encrypted in transit and session cookies cannot be intercepted, read, or stolen via XSS.

### Task 1: Enable `force_ssl` in production

**Files:**
- Modify: `config/runtime.exs`

**Step 1: Add force_ssl configuration**

In `config/runtime.exs`, inside the `if config_env() == :prod do` block, uncomment and configure `force_ssl`:

```elixir
config :slackex, SlackexWeb.Endpoint,
  force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]
```

The `rewrite_on: [:x_forwarded_proto]` is required because Caddy terminates TLS and forwards HTTP to Phoenix. Without it, Phoenix would see all requests as HTTP and redirect-loop.

**Step 2: Verify locally**

```bash
MIX_ENV=prod mix compile --no-deps-check
```

Expected: Compiles without error.

**Step 3: Commit**

```bash
git add config/runtime.exs
git commit -m "security: enable force_ssl with HSTS in production"
```

---

### Task 2: Encrypt session cookie and add security flags

**Files:**
- Modify: `lib/slackex_web/endpoint.ex`

**Step 1: Generate an encryption salt**

```bash
elixir -e "IO.puts(:crypto.strong_rand_bytes(8) |> Base.encode64())"
```

**Step 2: Update session options**

In `lib/slackex_web/endpoint.ex`, replace the `@session_options` definition:

```elixir
@session_options [
  store: :cookie,
  key: "_slackex_key",
  signing_salt: "Vx7ryvLt",
  encryption_salt: "<generated-salt>",
  same_site: "Lax",
  secure: true,
  http_only: true
]
```

Note: `secure: true` means the cookie won't be sent over HTTP in development. If this causes friction, gate it:

```elixir
@session_options [
  store: :cookie,
  key: "_slackex_key",
  signing_salt: "Vx7ryvLt",
  encryption_salt: "<generated-salt>",
  same_site: "Lax",
  secure: Application.compile_env(:slackex, :env) == :prod,
  http_only: true
]
```

**Step 3: Run tests**

```bash
mix test
```

Expected: All tests pass (test env uses the same session options but HTTP, so gate `secure` if needed).

**Step 4: Commit**

```bash
git add lib/slackex_web/endpoint.ex
git commit -m "security: encrypt session cookie and add secure/httponly flags"
```

---

### Task 3: Secure remember-me cookie

**Files:**
- Modify: `lib/slackex_web/user_auth.ex`

**Step 1: Update remember-me cookie options**

In `lib/slackex_web/user_auth.ex`, replace the `@remember_me_options`:

```elixir
@remember_me_options [
  sign: true,
  max_age: @max_age,
  same_site: "Lax",
  secure: true,
  http_only: true
]
```

Same `secure` gating consideration as Task 2 applies.

**Step 2: Run tests**

```bash
mix test
```

Expected: All tests pass.

**Step 3: Commit**

```bash
git add lib/slackex_web/user_auth.ex
git commit -m "security: add secure/httponly flags to remember-me cookie"
```

---

## Phase 2: Authentication Hardening

**Goal:** Prevent brute-force attacks on login endpoints and reduce session theft window.

### Task 4: Add rate limiting to login endpoints

**Files:**
- Create: `lib/slackex_web/plugs/rate_limit_login.ex`
- Modify: `lib/slackex_web/router.ex`
- Create: `test/slackex_web/plugs/rate_limit_login_test.exs`

**Step 1: Write the failing tests**

Create `test/slackex_web/plugs/rate_limit_login_test.exs`:

```elixir
defmodule SlackexWeb.Plugs.RateLimitLoginTest do
  use SlackexWeb.ConnCase, async: false

  alias SlackexWeb.Plugs.RateLimitLogin

  @max_attempts 5

  setup do
    RateLimitLogin.reset()
    :ok
  end

  describe "call/2" do
    test "allows requests under the limit" do
      conn = build_conn(:post, "/users/log-in")

      for _ <- 1..@max_attempts do
        result = RateLimitLogin.call(conn, RateLimitLogin.init([]))
        refute result.halted
      end
    end

    test "blocks requests over the limit" do
      conn = build_conn(:post, "/users/log-in")

      for _ <- 1..@max_attempts do
        RateLimitLogin.call(conn, RateLimitLogin.init([]))
      end

      result = RateLimitLogin.call(conn, RateLimitLogin.init([]))
      assert result.halted
      assert result.status == 429
    end

    test "different IPs have independent limits" do
      for _ <- 1..@max_attempts do
        conn = %{build_conn(:post, "/users/log-in") | remote_ip: {1, 2, 3, 4}}
        RateLimitLogin.call(conn, RateLimitLogin.init([]))
      end

      conn = %{build_conn(:post, "/users/log-in") | remote_ip: {5, 6, 7, 8}}
      result = RateLimitLogin.call(conn, RateLimitLogin.init([]))
      refute result.halted
    end
  end
end
```

**Step 2: Implement the plug**

Create `lib/slackex_web/plugs/rate_limit_login.ex`:

```elixir
defmodule SlackexWeb.Plugs.RateLimitLogin do
  @moduledoc """
  Rate-limits login attempts per IP address.

  Uses an ETS table to track attempts within a sliding window.
  Limits: 5 attempts per 60 seconds per IP.
  """

  import Plug.Conn

  @table :login_rate_limits
  @max_attempts 5
  @window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    ensure_table()
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    now = System.monotonic_time(:millisecond)
    key = {:login, ip}

    attempts = get_attempts(key, now)

    if length(attempts) >= @max_attempts do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(429, "Too many login attempts. Please try again later.")
      |> halt()
    else
      :ets.insert(@table, {key, [now | attempts]})
      conn
    end
  end

  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table])
    end
  end

  defp get_attempts(key, now) do
    cutoff = now - @window_ms

    case :ets.lookup(@table, key) do
      [{^key, timestamps}] -> Enum.filter(timestamps, &(&1 > cutoff))
      [] -> []
    end
  end
end
```

**Step 3: Initialize ETS in application.ex**

Add to `lib/slackex/application.ex`, before the supervisor children list:

```elixir
SlackexWeb.Plugs.RateLimitLogin.reset()
```

**Step 4: Wire into router**

In `lib/slackex_web/router.ex`, add the plug to the session login route. Find the scope that contains `UserSessionController` and add:

```elixir
scope "/", SlackexWeb do
  pipe_through [:browser, :redirect_if_user_is_authenticated]

  # ... existing routes ...
  post "/users/log-in", UserSessionController, :create
end
```

Add the plug to the browser pipeline or create a dedicated pipeline:

```elixir
pipeline :rate_limited_browser do
  plug :accepts, ["html"]
  plug SlackexWeb.Plugs.RateLimitLogin
end
```

For the API login endpoint, add the same plug to the API auth scope.

**Step 5: Run tests**

```bash
mix test test/slackex_web/plugs/rate_limit_login_test.exs
mix test
```

Expected: All tests pass.

**Step 6: Commit**

```bash
git add lib/slackex_web/plugs/rate_limit_login.ex test/slackex_web/plugs/rate_limit_login_test.exs lib/slackex_web/router.ex lib/slackex/application.ex
git commit -m "security: add rate limiting to login endpoints (5 attempts/60s per IP)"
```

---

### Task 5: Hash session tokens in database

**Files:**
- Modify: `lib/slackex/accounts/user_token.ex`

**Step 1: Update `build_session_token/1` to hash before storage**

```elixir
def build_session_token(user) do
  token = :crypto.strong_rand_bytes(@rand_size)
  hashed = :crypto.hash(:sha256, token)
  {token, %__MODULE__{token: hashed, context: "session", user_id: user.id}}
end
```

**Step 2: Update `verify_session_token_query/1` to hash on lookup**

```elixir
def verify_session_token_query(token) do
  hashed = :crypto.hash(:sha256, token)

  query =
    from token in by_token_and_context_query(hashed, "session"),
      join: user in assoc(token, :user),
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      select: user

  {:ok, query}
end
```

**Step 3: Update `delete_session_token/1` to hash before delete**

Find the function that deletes session tokens by raw token and add hashing:

```elixir
def delete_session_token(token) do
  hashed = :crypto.hash(:sha256, token)
  Repo.delete_all(by_token_and_context_query(hashed, "session"))
  :ok
end
```

**Step 4: Run tests**

```bash
mix test
```

Expected: All tests pass. Existing sessions will be invalidated (users must re-login after deploy — acceptable for a security fix).

**Step 5: Commit**

```bash
git add lib/slackex/accounts/user_token.ex
git commit -m "security: hash session tokens with SHA-256 before database storage"
```

---

### Task 6: Reduce session validity to 14 days

**Files:**
- Modify: `lib/slackex/accounts/user_token.ex`
- Modify: `lib/slackex_web/user_auth.ex`

**Step 1: Update session validity**

In `lib/slackex/accounts/user_token.ex`:

```elixir
@session_validity_in_days 14
```

**Step 2: Update remember-me max_age**

In `lib/slackex_web/user_auth.ex`:

```elixir
@max_age 60 * 60 * 24 * 14
```

**Step 3: Run tests**

```bash
mix test
```

Expected: All tests pass.

**Step 4: Commit**

```bash
git add lib/slackex/accounts/user_token.ex lib/slackex_web/user_auth.ex
git commit -m "security: reduce session validity from 60 to 14 days"
```

---

## Phase 3: Infrastructure & Headers

**Goal:** Add Content Security Policy, authenticate Redis, and harden deployment.

### Task 7: Add Content Security Policy header

**Files:**
- Modify: `lib/slackex_web/router.ex`

**Step 1: Update `put_secure_browser_headers` in the browser pipeline**

In `lib/slackex_web/router.ex`, replace:

```elixir
plug :put_secure_browser_headers
```

with:

```elixir
plug :put_secure_browser_headers, %{
  "content-security-policy" =>
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self' wss:; frame-ancestors 'none'"
}
```

Notes:
- `'unsafe-inline'` for styles is required for Phoenix LiveView's inline style attributes and daisyUI.
- `wss:` in connect-src is required for LiveView WebSocket connections.
- `frame-ancestors 'none'` replaces X-Frame-Options DENY.
- Refine the policy after deployment if specific external resources are needed.

**Step 2: Run tests**

```bash
mix test
```

Expected: All tests pass. CSP headers don't affect test execution.

**Step 3: Commit**

```bash
git add lib/slackex_web/router.ex
git commit -m "security: add Content Security Policy header to browser pipeline"
```

---

### Task 8: Add Redis authentication in production

**Files:**
- Modify: `docker-compose.prod.yml`
- Modify: `.env.example`

**Step 1: Add `requirepass` to Redis**

In `docker-compose.prod.yml`, update the Redis service command:

```yaml
redis:
  image: redis:7-alpine
  restart: unless-stopped
  command: >
    redis-server
    --requirepass ${REDIS_PASSWORD}
    --maxmemory 128mb
    --maxmemory-policy allkeys-lru
  volumes:
    - redisdata:/data
  healthcheck:
    test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
    interval: 5s
    timeout: 5s
    retries: 5
```

**Step 2: Update app environment to include password in REDIS_URL**

In the `x-app` environment section of `docker-compose.prod.yml`:

```yaml
REDIS_URL: "redis://:${REDIS_PASSWORD}@redis:6379"
```

**Step 3: Update `.env.example`**

Add:

```
REDIS_PASSWORD=change-me-to-a-strong-password
```

**Step 4: Set the password on the production server**

SSH to the deploy host and add `REDIS_PASSWORD` to the `.env` file at `/root/slackex/.env`.

**Step 5: Commit**

```bash
git add docker-compose.prod.yml .env.example
git commit -m "security: add Redis authentication in production"
```

---

### Task 9: Gate `/ui-mockups` route to dev-only

**Files:**
- Modify: `lib/slackex_web/router.ex`

**Step 1: Wrap the mockup route in dev_routes guard**

In `lib/slackex_web/router.ex`, move the mockup live_session inside the existing `dev_routes` block:

```elixir
if Application.compile_env(:slackex, :dev_routes) do
  scope "/", SlackexWeb do
    pipe_through :browser

    live_session :mockups, layout: false do
      live "/ui-mockups", MockupLive.Index, :index
    end
  end

  # ... existing dev_routes ...
end
```

**Step 2: Run tests**

```bash
mix test
```

Expected: All tests pass. If any test hits `/ui-mockups`, it should still work in test env (dev_routes is typically enabled in test).

**Step 3: Commit**

```bash
git add lib/slackex_web/router.ex
git commit -m "security: restrict /ui-mockups route to dev environment only"
```

---

## Phase 4: Input Validation & Cleanup

**Goal:** Harden input parsing, restrict JSON serialization, and add body size limits.

### Task 10: Replace `String.to_integer/1` with `Integer.parse/1`

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex`
- Modify: `lib/slackex/accounts/guardian.ex`

**Step 1: Find and replace all unsafe `String.to_integer` calls on user input**

In `lib/slackex_web/live/chat_live/index.ex`, replace each `String.to_integer(param)` pattern with:

```elixir
case Integer.parse(param) do
  {id, ""} -> # proceed with id
  _ -> {:noreply, socket}
end
```

This applies to approximately 9 locations (lines 251, 272, 290, 349, 392, 454, 497, 511, 516).

In `lib/slackex/accounts/guardian.ex`, update `resource_from_claims/1`:

```elixir
def resource_from_claims(%{"sub" => id}) do
  case Integer.parse(id) do
    {int_id, ""} ->
      user = Accounts.get_user!(int_id)
      {:ok, user}
    _ ->
      {:error, :invalid_claims}
  end
rescue
  Ecto.NoResultsError -> {:error, :resource_not_found}
end
```

**Step 2: Run tests**

```bash
mix test
```

Expected: All tests pass.

**Step 3: Commit**

```bash
git add lib/slackex_web/live/chat_live/index.ex lib/slackex/accounts/guardian.ex
git commit -m "security: replace String.to_integer with Integer.parse on user input"
```

---

### Task 11: Remove `:email` from User JSON derive

**Files:**
- Modify: `lib/slackex/accounts/user.ex`

**Step 1: Remove email from the Jason.Encoder derive**

In `lib/slackex/accounts/user.ex`, update the `@derive` to exclude `:email`:

```elixir
@derive {Jason.Encoder,
         only: [
           :id,
           :username,
           :display_name,
           :avatar_url,
           :status,
           :dm_preference,
           :inserted_at,
           :updated_at
         ]}
```

**Step 2: Check API controllers for explicit email serialization**

Grep for any API views/controllers that need to return email for the current user's own profile and add explicit email inclusion there (not via the derive).

**Step 3: Run tests**

```bash
mix test
```

Expected: Some API tests may fail if they assert on email in JSON responses — update those to check email through a dedicated profile endpoint instead.

**Step 4: Commit**

```bash
git add lib/slackex/accounts/user.ex
git commit -m "security: remove email from default User JSON serialization"
```

---

### Task 12: Add body size limit to Plug.Parsers

**Files:**
- Modify: `lib/slackex_web/endpoint.ex`

**Step 1: Add length option**

In `lib/slackex_web/endpoint.ex`, update the `Plug.Parsers` plug:

```elixir
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Phoenix.json_library(),
  length: 1_000_000
```

1MB is generous for a messaging app that processes text. Adjust if file uploads are added later.

**Step 2: Run tests**

```bash
mix test
```

Expected: All tests pass.

**Step 3: Commit**

```bash
git add lib/slackex_web/endpoint.ex
git commit -m "security: set 1MB body size limit on Plug.Parsers"
```

---

### Task 13: Add guard clause to `unsafe_fragment` SQL interpolation

**Files:**
- Modify: `lib/slackex/chat/chat.ex`

**Step 1: Add valid field guard**

Near the `upsert_read_cursor` function, add a guard:

```elixir
@valid_cursor_fields [:channel_id, :dm_conversation_id]

defp upsert_read_cursor(user_id, target_field, target_id)
     when target_field in @valid_cursor_fields do
  # existing implementation unchanged
end
```

This ensures that even if a future caller passes unexpected input, it will fail with a FunctionClauseError rather than SQL injection.

**Step 2: Run tests**

```bash
mix test
```

Expected: All tests pass.

**Step 3: Commit**

```bash
git add lib/slackex/chat/chat.ex
git commit -m "security: add guard clause to unsafe_fragment SQL interpolation"
```

---

### Task 14: Set explicit bcrypt log rounds for production

**Files:**
- Modify: `config/config.exs`

**Step 1: Add explicit bcrypt configuration**

In `config/config.exs`:

```elixir
config :bcrypt_elixir, log_rounds: 12
```

This makes the default explicit rather than relying on the library default. The existing `config/test.exs` override (`log_rounds: 4`) remains for fast tests.

**Step 2: Run tests**

```bash
mix test
```

Expected: All tests pass (test.exs override takes precedence).

**Step 3: Commit**

```bash
git add config/config.exs
git commit -m "security: set explicit bcrypt log_rounds for production"
```

---

## Phase 5: Missing Auth Flows

**Goal:** Add email confirmation and password reset — standard auth flows that are currently absent.

> **Note:** This phase is larger and may warrant its own detailed plan document (`docs/plans/2026-MM-DD-auth-flows.md`). The tasks below are architectural outlines rather than step-by-step implementations.

### Task 15: Add email confirmation flow

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_add_confirmed_at_to_users.exs`
- Modify: `lib/slackex/accounts/user.ex` — add `confirmed_at` field
- Modify: `lib/slackex/accounts/user_token.ex` — add `confirm` token type
- Modify: `lib/slackex/accounts/accounts.ex` — add `deliver_user_confirmation_instructions/2`, `confirm_user/1`
- Create: `lib/slackex_web/controllers/user_confirmation_controller.ex`
- Modify: `lib/slackex_web/user_auth.ex` — check `confirmed_at` in `require_authenticated_user`
- Modify: `lib/slackex_web/router.ex` — add confirmation routes
- Create: `lib/slackex/accounts/user_notifier.ex` — email delivery (or integrate with existing notifier if present)

**Architecture:**
1. Migration adds nullable `confirmed_at` (utc_datetime_usec) to users. Backfill existing users as confirmed.
2. Registration sends a confirmation email with a time-limited token (24h).
3. `require_authenticated_user` redirects unconfirmed users to a "please confirm your email" page.
4. Confirmation token is hashed before storage (matching JWT JTI pattern).
5. Resend confirmation endpoint with rate limiting.

---

### Task 16: Add password reset flow

**Files:**
- Modify: `lib/slackex/accounts/user_token.ex` — add `reset_password` token type
- Modify: `lib/slackex/accounts/accounts.ex` — add `deliver_user_reset_password_instructions/2`, `reset_user_password/2`
- Create: `lib/slackex_web/controllers/user_reset_password_controller.ex`
- Create: `lib/slackex_web/controllers/user_reset_password_html/new.html.heex`
- Create: `lib/slackex_web/controllers/user_reset_password_html/edit.html.heex`
- Modify: `lib/slackex_web/router.ex` — add reset password routes

**Architecture:**
1. `POST /users/reset-password` accepts email, always returns success (prevents user enumeration).
2. Token sent via email, valid for 1 hour, hashed before storage.
3. `PUT /users/reset-password/:token` accepts new password, invalidates all existing sessions.
4. Rate-limited: 3 reset requests per email per hour.

---

### Task 17: Create a dedicated deploy user (non-root)

**Files:**
- Modify: `.github/workflows/ci-deploy.yml`

**Architecture:**
1. On the production server, create a `deploy` user with Docker group membership.
2. Move deployment directory to `/opt/slackex/` owned by `deploy`.
3. Update CI to SSH as `deploy@host` instead of `root@host`.
4. Restrict `deploy` user's sudo to only `docker compose` commands.

---

## Verification Checklist

After all phases are complete, verify:

- [ ] `curl -sI http://chat.davewil.dev` returns 301 redirect to HTTPS
- [ ] `curl -sI https://chat.davewil.dev` includes `strict-transport-security` header
- [ ] `curl -sI https://chat.davewil.dev` includes `content-security-policy` header
- [ ] Session cookie in browser has `Secure`, `HttpOnly`, and is encrypted (opaque value)
- [ ] Remember-me cookie has `Secure` and `HttpOnly` flags
- [ ] 6th rapid login attempt returns 429
- [ ] `/ui-mockups` returns 404 in production
- [ ] Redis requires authentication (`redis-cli -a <password> ping` → PONG, `redis-cli ping` → NOAUTH)
- [ ] `mix test` passes with zero failures
- [ ] `mix dialyzer` passes with zero warnings

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| `force_ssl` causes redirect loop behind Caddy | `rewrite_on: [:x_forwarded_proto]` trusts Caddy's header |
| `secure: true` on cookies breaks dev login | Gate with `compile_env(:slackex, :env) == :prod` |
| Session token hashing invalidates existing sessions | Acceptable — users re-login once after deploy |
| Reduced session validity (60→14 days) surprises users | Still generous for a messaging app; add "remember me" UX if needed |
| CSP blocks unexpected resources | Start permissive, tighten iteratively after production observation |
| Redis password change requires coordinated deploy | Deploy new config first (app tolerates auth failure briefly), then restart Redis |
