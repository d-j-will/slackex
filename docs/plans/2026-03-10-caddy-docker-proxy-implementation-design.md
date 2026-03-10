# Caddy-Docker-Proxy Implementation Design

**Date**: 2026-03-10
**Status**: Approved
**Parent**: `docs/2026-03-10-caddy-docker-proxy-migration-design.md`
**Scope**: slackex repo (Phase 1 only)

## Approach

Single PR with all file changes. Labels on `docker-compose.prod.yml` are inert until caddy-docker-proxy is running, so the PR can be merged and deployed before the server-side cutover. The cutover itself is manual and staged via test ports.

## New Files

### `infra/caddy/Dockerfile`

Custom caddy-docker-proxy image with Cloudflare DNS plugin. Pin the base image and xcaddy versions.

```dockerfile
FROM lucaslorentz/caddy-docker-proxy:ci-2.9
RUN xcaddy build --with github.com/caddy-dns/cloudflare
```

(Exact base tag to be verified against current releases during implementation.)

### `infra/caddy/Caddyfile`

Fallback for routes not backed by a container:

```
davewil.dev {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    respond "Hello from tono!"
}
```

### `infra/caddy/docker-compose.yml`

Standalone compose for the server at `/root/caddy/`. Contains:
- Custom caddy-docker-proxy image (built locally or from GHCR)
- Docker socket mount (`/var/run/docker.sock`)
- Ports 80/443
- Joins external `proxy` network
- CF token via `.env`
- Fallback Caddyfile bind-mount

## Modified Files

### `docker-compose.prod.yml`

Add caddy-docker-proxy labels to existing services:

- **app1**: `caddy`, `caddy.tls.dns`, `caddy.reverse_proxy` with health check labels (uri, interval, timeout, fail_duration, health_headers)
- **app2**: `caddy` (same domain), `caddy.reverse_proxy` (caddy-docker-proxy merges upstreams by domain)
- **grafana**: `caddy`, `caddy.tls.dns`, `caddy.reverse_proxy` for `grafana.davewil.dev`

### `.github/workflows/ci-deploy.yml`

Remove:
- Caddyfile `sed` rendering + SCP (lines 172-173)
- `docker restart caddy` (line 292)
- `CADDY_CF_TOKEN` env var from deploy step (line 151)

Add:
- SCP of `infra/caddy/` files to `/root/caddy/` on server (Dockerfile, Caddyfile, docker-compose.yml)

### Delete

- `Caddyfile` (root of repo) — replaced by container labels + fallback Caddyfile

## Server-Side Cutover (Manual Runbook)

Zero-downtime sequence:

1. SSH to server, `cd /root/caddy`
2. Create `.env` with `CF_API_TOKEN=<value from /root/slackex/.env CADDY_CF_TOKEN>`
3. Build the custom image: `docker compose build`
4. Start on test ports (edit compose to 8080:80, 8443:443): `docker compose up -d`
5. Verify: `curl -k -H "Host: chat.davewil.dev" https://localhost:8443/health`
6. Verify: `curl -k -H "Host: grafana.davewil.dev" https://localhost:8443`
7. Verify: `curl -k -H "Host: davewil.dev" https://localhost:8443`
8. **Cutover** (~5s downtime): `docker stop caddy && docker compose down && (edit ports back to 80/443) && docker compose up -d`
9. Verify production: `curl https://chat.davewil.dev/health`
10. Cleanup: `docker rm caddy && rm /opt/caddy/Caddyfile`

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Label merging (app1+app2 same domain) fails | Test on 8080/8443 before cutover |
| Cloudflare DNS plugin build fails | Pin xcaddy + plugin versions |
| Health check header syntax differs in labels vs Caddyfile | Verify against caddy-docker-proxy docs |
| Brief Grafana monitoring gap during cutover | Acceptable — internal tool, ~5s window |
| Stale CI fires `docker restart caddy` | Removed from CI in same PR |

## Out of Scope

- kuma_san_kanji labels (Phase 2, separate repo)
- grocery_planner (future)
- Extracting caddy compose to a dedicated infra repo
