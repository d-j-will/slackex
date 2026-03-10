# RCA: Unplanned Production Outage During Caddy-Docker-Proxy Migration

**Date**: 2026-03-10
**Duration**: ~20 minutes (estimated from first cutover attempt to production restore)
**Severity**: Full site outage (chat.davewil.dev, grafana.davewil.dev, davewil.dev)
**Versions**: v0.5.71–v0.5.74

## Summary

During the caddy-docker-proxy migration, the test-port verification phase accidentally destroyed the existing production Caddy container. The migration was designed for zero-downtime via test ports (8080/8443) running alongside the existing Caddy (80/443), but a Docker Compose container name collision caused the old Caddy to be replaced on the first `docker compose up -d`.

## Timeline

1. `scripts/caddy-cutover` ran `docker compose up -d` in `/root/caddy/`
2. Docker Compose found the existing standalone container named `caddy` and **recreated** it as part of the new Compose project
3. The new caddy-docker-proxy started on test ports (8080/8443) — but the old Caddy on 80/443 was already gone
4. Test-port verification failed (Docker API version mismatch → empty upstreams → TLS SNI issue)
5. Script cleanup ran `docker compose down`, removing the only Caddy container
6. Production was now unserved on 80/443 with no container to restore
7. Multiple debug cycles occurred while production remained down
8. After fixing all issues, caddy-docker-proxy was brought up on production ports, restoring service

## Root Cause

**Container name collision.** The old Caddy ran as a standalone container named `caddy`. The new `docker-compose.yml` defined a service also named `caddy` (resulting in container `caddy-caddy-1`). Docker Compose v2 detected the existing `caddy` container on the shared `proxy` network and adopted/recreated it as part of the new project, destroying the production reverse proxy.

## Contributing Factors

1. **No pre-flight check for container name collision.** The cutover script verified SSH, infra files, and `.env`, but never checked whether a container named `caddy` already existed or whether `docker compose up` would interfere with it.

2. **Test-port phase assumed old Caddy would be untouched.** The design relied on the assumption that `docker compose up -d` in a separate directory would only manage its own containers. This assumption was wrong — Docker Compose matches by name and network, not just by project directory.

3. **Three sequential bugs masked the collision.** The Docker API version error (v0.5.72), the empty upstreams from cgroups (v0.5.73), and the TLS SNI issue were all discovered during test-port verification. Each required a fix → redeploy → retry cycle. If the first test had succeeded, the outage would have been shorter, but the container collision still would have occurred.

4. **No rollback verification.** The script's failure path ran `docker compose down` without checking whether the old Caddy was still running. A correct rollback would have detected that the old Caddy was gone and warned the operator.

5. **Verification was done on the live server, not in a staging environment.** All three bugs (Docker API version, cgroups/ingress networks, TLS SNI) would have been caught in a local Docker environment or a staging LXC. The production server was used as the test bed.

## What Should Have Happened

1. The cutover script should have renamed the service to avoid collision (e.g., `caddy-proxy` instead of `caddy`)
2. OR: the script should have stopped the old Caddy explicitly before starting caddy-docker-proxy, accepting that test-port verification runs on the only proxy (still recoverable via `docker start caddy` on failure)
3. Pre-flight check: `docker ps --filter name=caddy` to detect the existing container and warn/abort
4. Rollback check: before `docker compose down`, verify old Caddy is still serving 80/443

## Fixes Applied

### Immediate (during incident)
- Brought caddy-docker-proxy up on production ports once all three bugs were resolved
- Certificates had already been issued during test-port phase and were cached in the Docker volume

### Permanent (to prevent recurrence)

**1. Rename the service to `caddy-proxy` to avoid future name collisions:**

In `infra/caddy/docker-compose.yml`, change the service name from `caddy` to `caddy-proxy`. This ensures Docker Compose never collides with standalone containers named `caddy` on other hosts or in future migrations.

**2. Add pre-flight container check to cutover script:**

Before starting caddy-docker-proxy, check for existing containers that could collide:
```bash
if ssh_cmd "docker ps -q --filter name=^caddy$" | grep -q .; then
  warn "Existing 'caddy' container detected. Stopping it before proceeding."
  ssh_cmd "docker stop caddy"
fi
```

**3. Increase wait time and use correct curl SNI:**

Already applied during incident — 90s wait for ACME, `--resolve` flag for proper TLS SNI.

## Lessons Learned

1. **Docker Compose name collision is a non-obvious failure mode.** A container name that matches the service name in a different Compose project can be silently adopted and destroyed. Always use distinctive service names when multiple Compose projects share a Docker daemon.

2. **Test on a non-production environment first for infrastructure migrations.** All three bugs (Docker API version, LXC cgroups, TLS SNI) were environment-specific. A staging LXC with Docker 27+ would have caught all of them without production risk.

3. **The "zero-downtime" guarantee was never tested.** The design assumed `docker compose up` in a separate directory was safe. This assumption should have been verified with a manual `docker compose up --dry-run` or by reading Docker Compose's container adoption behavior.

4. **Multiple sequential bugs compound outage duration.** Each bug required a fix → commit → deploy → retry cycle. When the first bug hits on a live system, every subsequent bug extends the outage. Front-load all verification in a non-production environment.

## Action Items

- [ ] Rename service from `caddy` to `caddy-proxy` in `infra/caddy/docker-compose.yml`
- [ ] Update cutover script with pre-flight container check
- [ ] Add environment-specific gotchas to MEMORY.md (Docker 27+ API version, LXC cgroups, TLS SNI)
- [ ] Consider a staging LXC for future infrastructure migrations
