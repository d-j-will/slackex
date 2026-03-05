# Deployment Runbook

Production runs two app containers behind a Caddy reverse proxy on a Docker host. The CI/CD pipeline (`.github/workflows/ci-deploy.yml`) builds a Docker image, pushes to GHCR, SSHes into the server to pull and restart containers using `docker-compose.prod.yml`, then restarts Caddy to pick up new upstream IPs.

## Docker Compose rules

- **Always use `docker compose pull`**, never bare `docker pull` — hook-enforced. Compose tracks digests independently; bare pull silently leaves containers on the old image.
- **Always pass `--force-recreate --no-build --remove-orphans`** to `docker compose up`. `--force-recreate` ensures containers are replaced when the `:latest` digest changes. `--no-build` prevents rebuilding from stale local source. `--remove-orphans` cleans up containers from renamed/removed services that would otherwise keep running and intercept traffic.
- **Never define `build:` in `docker-compose.prod.yml`** — hook-enforced. Production always uses pre-built images from GHCR.
- **Keep the server's compose file in sync** with the repo. The deploy step must `scp docker-compose.prod.yml` to the server before running `docker compose` commands — the server has no `git pull`.
- **Authenticate GHCR on the server** before pulling from private repos. Use `echo "$GITHUB_TOKEN" | ssh host docker login ghcr.io -u actor --password-stdin` before the SSH heredoc.

## Caddy reverse proxy rules

- **Use `docker restart caddy`, not `caddy reload`** — hook-enforced. Full restart forces fresh DNS; `reload` retains stale upstream IPs when the Caddyfile is unchanged.
- **The Caddyfile is bind-mounted** from `/opt/caddy/Caddyfile` on the host into the Caddy container at `/etc/caddy/Caddyfile`. Edit the host file; it's the same file inside the container.
- **Never use `import` directives in the Caddyfile.** Only the single Caddyfile file is bind-mounted — files written alongside it on the host (e.g., `/opt/caddy/slackex-proxy`) are not visible inside the container. `import` references to host paths cause Caddy to crash-loop on startup. Keep the full config inline.
- **Never dump Caddyfile contents to CI logs** — it contains API tokens (e.g., Cloudflare DNS challenge credentials). Use targeted checks (e.g., `grep reverse_proxy /opt/caddy/Caddyfile`) when debugging.
- **Enable active health checks** on `reverse_proxy` for automatic failover. Use `health_uri /health`, `health_interval 5s`, `health_timeout 3s`, `fail_duration 15s` inside the `reverse_proxy` block. Without health checks, stopping one node returns 502 for requests routed to it. The reference config is in the repo's `Caddyfile`.
- **Health checks require `health_headers { X-Forwarded-Proto https }`** when the app uses `force_ssl`. Caddy's health checker makes a plain HTTP request without forwarded-proto headers; Phoenix sees it as insecure and returns 301, which Caddy treats as unhealthy, marking all upstreams down and returning 503 to every request.

## SSH heredoc rules

- **Redirect stdin from `/dev/null`** on any `docker compose exec`, `docker compose run`, or interactive command inside an SSH heredoc (`ssh host << 'EOF'`). These commands read from stdin by default, which **consumes the rest of the heredoc** — silently eating all subsequent commands. The shell exits 0, CI reports success, but nothing runs. Always use `docker compose exec ... < /dev/null`.
- **Redirect stderr to stdout (`2>&1`)** on all `docker compose` commands. Docker Compose writes progress and errors to stderr, which SSH heredocs don't forward to CI logs by default.
- **Add echo markers** before and after every deploy step. These appear in CI logs and make it trivial to spot where a deploy stalled or failed.
- **Make pre-deploy operations non-fatal** (e.g., database backups). Use `cmd && echo "done" || echo "failed (non-fatal)"` instead of relying on `set -e` for best-effort steps.

## Phoenix release config

- **Compile-time endpoint keys must be set in `config/prod.exs`**, not only in `config/runtime.exs`. Phoenix validates that compile-time config matches runtime values at boot — a mismatch crashes the release. Keys like `force_ssl`, `url`, `server`, and `cache_static_manifest` are compile-time. Set the value in `prod.exs` and (if needed) repeat or override it in `runtime.exs`.
- **After adding any endpoint config in `runtime.exs`**, check whether Phoenix treats it as compile-time by searching for `@compile_env` in the Phoenix source or testing with `MIX_ENV=prod mix compile` followed by a release boot.

## Pre-deploy verification

Run `scripts/pre-deploy` to execute the full checklist (tests, formatting, credo, dialyzer, YAML, Docker build, release boot). Or use `/deploy` which orchestrates this automatically.

## Hardware constraints

**The production server is a mini-PC with a flaky GPU. GPU is OFF-LIMITS.**

- Never enable GPU-accelerated workloads (EXLA, CUDA, OpenCL) in production config
- EXLA defaults to GPU when available — if EXLA must run, force CPU-only: `EXLA_TARGET=host`
- Violating this constraint crashes the physical server, not just the app or VM

## Tailscale DNS

The Docker host uses Tailscale for networking. **Tailscale's DNS resolver (`100.100.100.100`) fails after VM reboots**, blocking Docker pulls and all outbound DNS.

- **`/etc/systemd/system/fix-dns.service`** runs on boot to disable Tailscale DNS and set Google DNS (8.8.8.8)
- **CI deploy pipeline** includes a DNS check before `docker compose pull`
- If DNS is broken on the host: `tailscale set --accept-dns=false && echo "nameserver 8.8.8.8" > /etc/resolv.conf`

## Infrastructure resilience

The Docker host runs as a Proxmox VM. Defense in depth for uptime:
1. **Container level**: `restart: unless-stopped` handles process crashes
2. **Application level**: `restart: :temporary` on non-essential supervisors prevents cascade
3. **VM level**: Proxmox HA auto-restarts crashed VMs
4. **Monitoring level**: External health check alerts on downtime

Configuration:
- Enable HA in Proxmox for the Docker host VM
- Set a fixed memory allocation (no ballooning)
- Monitor the VM from outside (Proxmox, UptimeRobot, or a cron on another host)

## General

- **Deploys only trigger on version tags** (`refs/tags/v*`). Pushing to `master` runs CI quality checks only.
- **Always check the latest tag before creating a new one** — run `git tag --sort=-creatordate | head -5` and increment from the highest existing version.
