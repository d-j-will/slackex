# Caddy-Docker-Proxy Migration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the static Caddyfile managed by CI with caddy-docker-proxy, so each app manages its own reverse proxy config via Docker labels.

**Architecture:** Multi-stage custom Caddy image (caddy + caddy-docker-proxy plugin + Cloudflare DNS plugin). Standalone compose on the server. App containers declare labels. CI deploys infra files; caddy-docker-proxy auto-discovers containers.

**Tech Stack:** Docker, caddy-docker-proxy, xcaddy, caddy-dns/cloudflare, GitHub Actions

**Parent design:** `docs/2026-03-10-caddy-docker-proxy-migration-design.md`
**Implementation design:** `docs/plans/2026-03-10-caddy-docker-proxy-implementation-design.md`

**Doc verification sources:**
- [caddy-docker-proxy README](https://github.com/lucaslorentz/caddy-docker-proxy) — label syntax, `{{upstreams}}` template
- [Caddy reverse_proxy directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) — health check subdirective names
- [Caddy Community: building with cloudflare + docker-proxy](https://caddy.community/t/solved-building-caddy-with-caddy-docker-proxy-caddy-dns-cloudflare/10954) — multi-stage Dockerfile pattern
- [Issue #733](https://github.com/lucaslorentz/caddy-docker-proxy/issues/733) — merge behavior (Caddyfile + labels doesn't merge; two containers with same domain labels DO merge reverse_proxy upstreams)
- [DeepWiki: Docker Labels](https://deepwiki.com/lucaslorentz/caddy-docker-proxy/3.1-docker-labels) — dot-notation nesting rules

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `infra/caddy/Dockerfile` | Multi-stage build: caddy + docker-proxy plugin + Cloudflare DNS |
| `infra/caddy/docker-compose.yml` | Standalone caddy-docker-proxy service for the server |
| `infra/caddy/Caddyfile` | Fallback routes not backed by a container (`davewil.dev`) |

### Modified Files
| File | Change |
|------|--------|
| `docker-compose.prod.yml` | Add caddy-docker-proxy labels to app1, app2, grafana |
| `.github/workflows/ci-deploy.yml` | Remove Caddyfile management, add caddy infra SCP |

### Deleted Files
| File | Reason |
|------|--------|
| `Caddyfile` (root) | Replaced by container labels + fallback Caddyfile |

---

## Chunk 1: Infrastructure Files

### Task 1: Create the custom Caddy Dockerfile

**Files:**
- Create: `infra/caddy/Dockerfile`

**IMPORTANT:** The design doc's single-line Dockerfile is wrong. caddy-docker-proxy is a Caddy plugin, not a standalone image you extend. You must build a custom Caddy binary with both the docker-proxy plugin AND the Cloudflare DNS plugin using xcaddy, then set the correct CMD.

- [ ] **Step 1: Create `infra/caddy/Dockerfile`**

```dockerfile
ARG CADDY_VERSION=2.9.1
FROM caddy:${CADDY_VERSION}-builder AS builder

RUN xcaddy build v${CADDY_VERSION} \
    --with github.com/lucaslorentz/caddy-docker-proxy/plugin/v2 \
    --with github.com/caddy-dns/cloudflare

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

CMD ["caddy", "docker-proxy"]
```

**Why multi-stage:** The builder image includes Go toolchain (~1GB). The final image is just the compiled binary on Alpine (~40MB). The `CMD ["caddy", "docker-proxy"]` is critical — without it, caddy runs in normal mode and ignores Docker labels entirely.

- [ ] **Step 2: Verify the Caddy version is current**

Run: check [Docker Hub caddy tags](https://hub.docker.com/_/caddy/tags) or run:
```bash
docker pull caddy:2.9.1-builder --quiet 2>/dev/null && echo "2.9.1 exists" || echo "check latest version"
```

If 2.9.1 doesn't exist, update the ARG to the latest 2.x stable.

- [ ] **Step 3: Commit**

```bash
git add infra/caddy/Dockerfile
git commit -m "feat(infra): add caddy-docker-proxy Dockerfile with Cloudflare DNS

Multi-stage build combining caddy-docker-proxy plugin and
caddy-dns/cloudflare for automatic HTTPS via DNS challenge."
```

---

### Task 2: Create the fallback Caddyfile

**Files:**
- Create: `infra/caddy/Caddyfile`

- [ ] **Step 1: Create `infra/caddy/Caddyfile`**

```
davewil.dev {
	tls {
		dns cloudflare {env.CF_API_TOKEN}
	}
	respond "Hello from tono!"
}
```

This handles the bare domain, which has no container behind it. caddy-docker-proxy loads this as a base Caddyfile and extends it with labels from discovered containers.

- [ ] **Step 2: Commit**

```bash
git add infra/caddy/Caddyfile
git commit -m "feat(infra): add fallback Caddyfile for davewil.dev"
```

---

### Task 3: Create the standalone docker-compose.yml

**Files:**
- Create: `infra/caddy/docker-compose.yml`

- [ ] **Step 1: Create `infra/caddy/docker-compose.yml`**

```yaml
services:
  caddy:
    build: .
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      CF_API_TOKEN: "${CF_API_TOKEN}"
      CADDY_DOCKER_CADDYFILE_PATH: "/etc/caddy/Caddyfile"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - proxy

volumes:
  caddy_data:
  caddy_config:

networks:
  proxy:
    external: true
```

**Key details:**
- Docker socket mount is required for container discovery
- `CADDY_DOCKER_CADDYFILE_PATH` tells caddy-docker-proxy where to find the fallback Caddyfile
- `caddy_data` persists TLS certificates (avoids re-issuing on restart)
- `caddy_config` persists runtime config
- Joins external `proxy` network (same one app containers are on)

- [ ] **Step 2: Commit**

```bash
git add infra/caddy/docker-compose.yml
git commit -m "feat(infra): add standalone caddy-docker-proxy compose

Runs independently on the server at /root/caddy/. Discovers app
containers via Docker socket and proxy network."
```

---

## Chunk 2: App Label Configuration

### Task 4: Add caddy-docker-proxy labels to docker-compose.prod.yml

**Files:**
- Modify: `docker-compose.prod.yml` (services: app1, app2, grafana)

**IMPORTANT on `health_headers`:** The Caddyfile `health_headers` directive uses a block for key-value pairs. In label dot-notation, this maps to: `caddy.reverse_proxy.health_headers.X-Forwarded-Proto: https` which generates:
```
health_headers {
    X-Forwarded-Proto https
}
```
This is different from the design doc's flat format. Verify during test-port phase (Task 7).

- [ ] **Step 1: Add labels to `app1` service**

In `docker-compose.prod.yml`, add a `labels` key to the `app1` service (after the existing `environment` block):

```yaml
  app1:
    <<: *app-defaults
    hostname: app1
    labels:
      caddy: chat.davewil.dev
      caddy.tls.dns: cloudflare {env.CF_API_TOKEN}
      caddy.reverse_proxy: "{{upstreams 4000}}"
      caddy.reverse_proxy.health_uri: /health
      caddy.reverse_proxy.health_interval: 5s
      caddy.reverse_proxy.health_timeout: 3s
      caddy.reverse_proxy.fail_duration: 15s
      caddy.reverse_proxy.health_headers.X-Forwarded-Proto: https
    networks:
      default:
      proxy:
        aliases:
          - app1
    environment:
      <<: *app-env
      RELEASE_NODE: "slackex@app1"
```

- [ ] **Step 2: Add labels to `app2` service**

app2 shares the same `caddy` domain. caddy-docker-proxy merges reverse_proxy upstreams from multiple containers with the same domain label, so app2 only needs the domain and reverse_proxy labels:

```yaml
  app2:
    <<: *app-defaults
    hostname: app2
    labels:
      caddy: chat.davewil.dev
      caddy.reverse_proxy: "{{upstreams 4000}}"
    networks:
      default:
      proxy:
        aliases:
          - app2
    environment:
      <<: *app-env
      RELEASE_NODE: "slackex@app2"
```

- [ ] **Step 3: Add labels to `grafana` service**

```yaml
  grafana:
    image: grafana/grafana:latest
    restart: unless-stopped
    mem_limit: 128m
    labels:
      caddy: grafana.davewil.dev
      caddy.tls.dns: cloudflare {env.CF_API_TOKEN}
      caddy.reverse_proxy: "{{upstreams 3000}}"
    ports:
      - "3002:3000"
    # ... rest unchanged
```

Note: Keep `ports: - "3002:3000"` for direct access on the server. The labels add external access via `grafana.davewil.dev`.

- [ ] **Step 4: Verify labels are syntactically valid YAML**

Run:
```bash
docker compose -f docker-compose.prod.yml config --quiet 2>&1 && echo "YAML valid" || echo "YAML invalid"
```

Expected: `YAML valid`

- [ ] **Step 5: Commit**

```bash
git add docker-compose.prod.yml
git commit -m "feat(infra): add caddy-docker-proxy labels to app1, app2, grafana

Labels are inert until caddy-docker-proxy is running. The existing
Caddy container ignores them, so this is safe to deploy before cutover."
```

---

## Chunk 3: CI Pipeline Changes

### Task 5: Update ci-deploy.yml

**Files:**
- Modify: `.github/workflows/ci-deploy.yml`

This task has two parts: remove old Caddyfile management, add new caddy infra file deployment.

**Read first:** `docs/engineering-principles.md` for SSH heredoc gotchas (per CLAUDE.md required reading).

- [ ] **Step 1: Remove `CADDY_CF_TOKEN` from deploy env block**

In the `Deploy to Docker host` step, remove this line from the `env:` block:
```yaml
          CADDY_CF_TOKEN: ${{ secrets.CADDY_CF_TOKEN }}
```

The CF token is now in `/root/caddy/.env` on the server, not injected via CI.

- [ ] **Step 2: Remove Caddyfile rendering and SCP**

Remove these lines (currently around lines 169-173):
```yaml
          # Render Caddyfile template (substitute token) and deploy directly to the Caddy config path.
          # Do NOT use `import` directives — only the Caddyfile itself is bind-mounted into the
          # Caddy container; files written alongside it on the host are invisible inside.
          sed "s|\${CADDY_CF_TOKEN}|${CADDY_CF_TOKEN}|g" Caddyfile > /tmp/Caddyfile.rendered
          scp /tmp/Caddyfile.rendered root@${{ secrets.DEPLOY_HOST }}:/opt/caddy/Caddyfile
```

- [ ] **Step 3: Add caddy infra file SCP**

Replace the removed Caddyfile lines with:
```yaml
          # Copy caddy-docker-proxy infra files to server
          ssh root@${{ secrets.DEPLOY_HOST }} "mkdir -p /root/caddy"
          scp infra/caddy/Dockerfile root@${{ secrets.DEPLOY_HOST }}:/root/caddy/Dockerfile
          scp infra/caddy/docker-compose.yml root@${{ secrets.DEPLOY_HOST }}:/root/caddy/docker-compose.yml
          scp infra/caddy/Caddyfile root@${{ secrets.DEPLOY_HOST }}:/root/caddy/Caddyfile
```

- [ ] **Step 4: Remove `docker restart caddy` from the SSH heredoc**

Inside the `<< 'EOF'` heredoc block, remove these lines (currently around line 289-292):
```bash
            # Restart Caddy to pick up the new config (rendered and SCPed above).
            # Full restart (not reload) clears stale DNS/connection state after container recreation.
            echo "Restarting Caddy..."
            docker restart caddy 2>&1 && echo "Caddy restarted." || echo "Caddy restart failed (non-fatal)"
```

Replace with:
```bash
            # Caddy-docker-proxy auto-discovers container changes — no restart needed.
            # If caddy-docker-proxy itself needs a rebuild, do it manually via /root/caddy/.
```

- [ ] **Step 5: Validate the workflow YAML**

Run:
```bash
gh workflow view ci-deploy.yml 2>/dev/null || echo "Use: python3 -c \"import yaml; yaml.safe_load(open('.github/workflows/ci-deploy.yml'))\" to validate"
```

Or:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci-deploy.yml')); print('YAML valid')"
```

Expected: `YAML valid`

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci-deploy.yml
git commit -m "feat(ci): replace Caddyfile management with caddy-docker-proxy infra deploy

- Remove Caddyfile sed/SCP and docker restart caddy
- Add SCP of caddy-docker-proxy Dockerfile, compose, and fallback Caddyfile
- Remove CADDY_CF_TOKEN from CI env (now in server .env)"
```

---

### Task 6: Delete root Caddyfile

**Files:**
- Delete: `Caddyfile`

- [ ] **Step 1: Delete the root Caddyfile**

```bash
git rm Caddyfile
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove root Caddyfile, replaced by caddy-docker-proxy labels

Routes are now defined via Docker labels on each service.
The fallback Caddyfile for davewil.dev lives at infra/caddy/Caddyfile."
```

---

## Chunk 4: Server-Side Cutover Runbook

### Task 7: Server-side cutover (manual, zero-downtime)

This is NOT automated. These are manual steps to run on the server after the PR is merged and deployed.

**Prerequisites:**
- PR merged and deployed (labels on containers, infra files on server)
- SSH access to the Docker host

- [ ] **Step 1: Create the proxy network (if it doesn't exist)**

```bash
ssh root@$DEPLOY_HOST "docker network inspect proxy >/dev/null 2>&1 || docker network create proxy"
```

The `proxy` network is already declared as `external: true` in `docker-compose.prod.yml`, so it should exist. Verify.

- [ ] **Step 2: Set up `/root/caddy/.env`**

```bash
ssh root@$DEPLOY_HOST 'cat > /root/caddy/.env << EOF
CF_API_TOKEN=<paste value from /root/slackex/.env CADDY_CF_TOKEN>
EOF'
```

The CF token value is the same one currently used by the old Caddy setup (stored as `CADDY_CF_TOKEN` on the server).

- [ ] **Step 3: Build the custom caddy image**

```bash
ssh root@$DEPLOY_HOST "cd /root/caddy && docker compose build"
```

This runs the multi-stage build (~2-3 minutes on first build). Verify it completes without error.

- [ ] **Step 4: Start on test ports**

Temporarily edit `/root/caddy/docker-compose.yml` on the server to use test ports:
```yaml
    ports:
      - "8080:80"
      - "8443:443"
```

Then start:
```bash
ssh root@$DEPLOY_HOST "cd /root/caddy && docker compose up -d"
```

- [ ] **Step 5: Verify all routes through test ports**

```bash
# chat.davewil.dev → app1/app2
curl -k -H "Host: chat.davewil.dev" https://$DEPLOY_HOST:8443/health
# Expected: {"status":"ok","cluster_size":2,...}

# grafana.davewil.dev → grafana
curl -k -H "Host: grafana.davewil.dev" https://$DEPLOY_HOST:8443
# Expected: 200 or 302 (Grafana login redirect)

# davewil.dev → fallback
curl -k -H "Host: davewil.dev" https://$DEPLOY_HOST:8443
# Expected: "Hello from tono!"
```

**If health checks fail:** Check the generated Caddyfile:
```bash
ssh root@$DEPLOY_HOST "docker exec caddy-caddy-1 caddy fmt --overwrite /config/caddy/autosave.json 2>/dev/null; docker exec caddy-caddy-1 cat /config/caddy/autosave.json"
```

This shows the actual config caddy-docker-proxy generated from labels. Compare against the expected Caddyfile to debug label syntax issues (especially `health_headers`).

- [ ] **Step 6: Cutover — swap ports (~5s downtime)**

```bash
ssh root@$DEPLOY_HOST << 'EOF'
  # Stop old Caddy
  docker stop caddy

  # Update caddy-docker-proxy to production ports
  cd /root/caddy
  sed -i 's/8080:80/80:80/' docker-compose.yml
  sed -i 's/8443:443/443:443/' docker-compose.yml
  docker compose up -d
EOF
```

- [ ] **Step 7: Verify production traffic**

```bash
curl -sf https://chat.davewil.dev/health
# Expected: {"status":"ok",...}

curl -sf https://grafana.davewil.dev -o /dev/null -w "%{http_code}"
# Expected: 200 or 302

curl -sf https://davewil.dev
# Expected: "Hello from tono!"
```

- [ ] **Step 8: Clean up old Caddy**

```bash
ssh root@$DEPLOY_HOST << 'EOF'
  docker rm caddy
  rm /opt/caddy/Caddyfile
  echo "Old Caddy removed."
EOF
```

- [ ] **Step 9: Verify caddy-docker-proxy auto-discovery works**

Restart one app container and confirm caddy-docker-proxy picks it up:
```bash
ssh root@$DEPLOY_HOST << 'EOF'
  cd /root/slackex
  docker compose -f docker-compose.prod.yml restart app1
  sleep 10
  curl -sf https://chat.davewil.dev/health
EOF
```

Expected: health check passes, showing app1 is back in the upstream pool.

---

## Chunk 5: Post-Migration Verification

### Task 8: Post-cutover CI deploy test

After the cutover is live, do a test deploy to verify the new CI pipeline works end-to-end.

- [ ] **Step 1: Tag a test release**

```bash
# Bump patch version
git tag v<next-version>
git push origin v<next-version>
```

- [ ] **Step 2: Monitor the deploy**

```bash
gh run watch
```

Verify:
- No Caddyfile-related errors
- No `docker restart caddy` errors
- Caddy infra files are SCPed successfully
- App containers start with labels
- Smoke tests pass

- [ ] **Step 3: Verify caddy-docker-proxy picked up the redeployed containers**

```bash
curl -sf https://chat.davewil.dev/health
```

Expected: healthy response, confirming caddy-docker-proxy auto-discovered the recreated containers.

---

## Known Risks & Verification Points

| Risk | Verification | Fallback |
|------|-------------|----------|
| `health_headers` label syntax generates wrong Caddyfile | Inspect generated config in Step 5 of Task 7 | Remove health_headers labels; health checks still work without custom headers (just slower — Phoenix returns 301 then 200) |
| app1+app2 upstreams not merged | `curl` through test port in Task 7 Step 5 | Put all labels on app1 only, list both upstreams explicitly |
| xcaddy build fails on server (Go compilation) | Task 7 Step 3 | Pre-build image in CI and push to GHCR |
| Caddy can't reach containers on proxy network | Test port verification | Check `docker network inspect proxy` for container membership |
| TLS certificate issuance fails on cutover | `curl` verification in Task 7 Step 7 | Caddy retries automatically; check logs with `docker logs caddy-caddy-1` |

## Rollback Plan

If anything goes wrong after cutover:

```bash
ssh root@$DEPLOY_HOST << 'EOF'
  # Stop caddy-docker-proxy
  cd /root/caddy && docker compose down

  # Restore old Caddy (if not yet removed)
  docker start caddy
  # Or re-deploy the old Caddyfile and start a fresh caddy container
EOF
```

The old Caddyfile is still in git history and can be re-rendered from CI by reverting the ci-deploy.yml changes.
