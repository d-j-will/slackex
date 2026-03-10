# Caddy-Docker-Proxy Migration Design

**Date**: 2026-03-10
**Status**: Approved
**Scope**: Cross-repo (slackex + kuma_san_kanji)

## Problem

The shared Caddyfile at `/opt/caddy/Caddyfile` on the Docker host is managed by the slackex CI/CD pipeline. Adding kuma_san_kanji (and soon grocery_planner) means multiple repos fighting over one file — fragile append logic, risk of overwrites, no clean way to remove entries.

## Solution

Replace the current static-Caddyfile Caddy container with `caddy-docker-proxy`, which auto-generates reverse proxy config from Docker container labels. Each app repo only manages its own container labels.

## Architecture

```
                    ┌─────────────────────────┐
                    │   caddy-docker-proxy     │
                    │   (listens 80/443)       │
                    │   reads container labels  │
                    │   + fallback Caddyfile   │
                    └────────┬────────────────┘
                             │ proxy network
              ┌──────────────┼──────────────────┐
              │              │                  │
         kanji-app:4000  app1/app2:4000    (future apps)
         (kuma_san_kanji)  (slackex)       (grocery_planner)
```

## Components

### 1. Custom Caddy Image

A 3-line Dockerfile that builds from `lucaslorentz/caddy-docker-proxy` and adds the Cloudflare DNS plugin via xcaddy. This is needed because caddy-docker-proxy doesn't include the Cloudflare module by default.

### 2. Standalone Caddy Compose (`/root/caddy/docker-compose.yml`)

Lives on the server as shared infrastructure (option A). Independent of any app repo. Contains:
- The custom caddy-docker-proxy image
- Docker socket mount for container discovery
- Ports 80/443
- Joins `proxy` network
- CF token via `.env`
- Fallback Caddyfile for non-container routes

### 3. Fallback Caddyfile

For routes not backed by a container:

```
davewil.dev {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    respond "Hello from tono!"
}
```

### 4. App Container Labels

Each app adds labels to its compose services. Example for kuma_san_kanji:

```yaml
app:
  labels:
    caddy: kanji.davewil.dev
    caddy.tls.dns: cloudflare {env.CF_API_TOKEN}
    caddy.reverse_proxy: "{{upstreams 4000}}"
    caddy.reverse_proxy.health_uri: /health
    caddy.reverse_proxy.health_interval: 5s
    caddy.reverse_proxy.health_headers: "X-Forwarded-Proto https"
```

Example for slackex (two upstreams with health checks):

```yaml
app1:
  labels:
    caddy: chat.davewil.dev
    caddy.tls.dns: cloudflare {env.CF_API_TOKEN}
    caddy.reverse_proxy: "{{upstreams 4000}}"
    caddy.reverse_proxy.health_uri: /health
    caddy.reverse_proxy.health_interval: 5s
    caddy.reverse_proxy.health_timeout: 3s
    caddy.reverse_proxy.fail_duration: 15s
    caddy.reverse_proxy.health_headers: "X-Forwarded-Proto https"

app2:
  labels:
    caddy: chat.davewil.dev
    caddy.reverse_proxy: "{{upstreams 4000}}"
```

Grafana:

```yaml
grafana:
  labels:
    caddy: grafana.davewil.dev
    caddy.tls.dns: cloudflare {env.CF_API_TOKEN}
    caddy.reverse_proxy: "{{upstreams 3000}}"
```

### 5. CI Deploy Simplification

Remove from all app CI pipelines:
- Caddyfile SCP/append/render logic
- `docker restart caddy` step

The deploy becomes: pull image → migrate → recreate containers. Caddy-docker-proxy auto-detects new/updated containers.

## Migration Order (zero-downtime)

1. **Build caddy-docker-proxy image** with Cloudflare DNS plugin
2. **Deploy on test ports** (8080/8443) alongside existing Caddy on the server
3. **Update slackex compose** with labels (app1, app2, grafana) — PR in slackex repo
4. **Test through caddy-docker-proxy** on test ports
5. **Cutover**: stop old Caddy, update caddy-docker-proxy to 80/443, restart
6. **Verify slackex** is live on new proxy
7. **Deploy kuma_san_kanji** with labels — auto-discovered
8. **Remove old Caddy** container and `/opt/caddy/Caddyfile`

**Critical**: slackex changes go first because it's the live production app.

## Work Split

### Phase 1: slackex repo (do first)
- Build custom caddy-docker-proxy + Cloudflare image
- Create standalone Caddy compose for the server
- Add labels to slackex compose services
- Create fallback Caddyfile for `davewil.dev`
- Update slackex CI deploy to remove Caddyfile management
- Test and cutover on the server

### Phase 2: kuma_san_kanji repo (do after)
- Replace `Caddyfile` with Docker labels in `docker-compose.prod.yml`
- Remove Caddyfile SCP/append logic from CI deploy
- Delete `Caddyfile` from repo
- First deploy of kuma_san_kanji

## Cloudflare Setup (for kanji.davewil.dev)

1. Add DNS `A` record: `kanji` → server public IP, DNS only (grey cloud)
2. Reuse existing `CADDY_CF_TOKEN` (same Cloudflare zone)

## GitHub Actions Secrets (for kuma_san_kanji)

| Secret | Description | Shared with slackex? |
|--------|-------------|---------------------|
| `DEPLOY_SSH_KEY` | Ed25519 SSH key for Docker host | Yes |
| `DEPLOY_HOST` | Tailscale IP of Docker host | Yes |
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID | Yes |
| `TAILSCALE_AUTHKEY` | Tailscale OAuth secret | Yes |
| `CADDY_CF_TOKEN` | Cloudflare API token | Yes |

`GITHUB_TOKEN` is automatic.

## Server .env for kuma_san_kanji (`/root/kuma_san_kanji/.env`)

```
POSTGRES_PASSWORD=<openssl rand -hex 32>
SECRET_KEY_BASE=<mix phx.gen.secret>
TOKEN_SIGNING_SECRET=<mix phx.gen.secret>
AUTH0_CLIENT_ID=<from Auth0>
AUTH0_CLIENT_SECRET=<from Auth0>
AUTH0_DOMAIN=<https://your-tenant.auth0.com>
ADMIN_EMAIL=<admin email>
```

## Out of Scope

- grocery_planner (just adds labels when ready)
- OTEL integration for kuma_san_kanji (add env vars later)
- Infra repo (caddy compose lives on server for now, can be extracted later)
