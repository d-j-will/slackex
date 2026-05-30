# Slackex

A production-grade Phoenix/LiveView messaging application — realtime messaging, channels, DMs, threads, reactions, push notifications, hybrid (full-text + semantic) search, and agent-facing MCP integrations. Deployed to a self-hosted homelab behind a fully automated CI/CD pipeline.

## Context

This repository is a **code sample**. I keep it to the same standard as professional work — it is evidence of *how* I build, not just *what* I build:

- **Spec-first** — features start as design docs and ADRs before any code (`docs/feature/*/design/`).
- **Test-driven** — 1,600+ tests; tests land in the same commit as the feature they cover.
- **Trunk-based CI/CD** — small conventional commits straight to `master`; the same checks run locally and in CI.
- **Dark-shipped** — incomplete work sits behind feature flags that gate every surface (UI, routes, tests).
- **AI as an accelerant within rigour** — `CLAUDE.md` is an engineering rulebook (Ecto upsert safety, no silent rescues, mandatory library-doc verification), not a "write my code" prompt. Commits carry `Co-Authored-By` trailers: I orchestrate and review, the standards are mine.
- **Operated for real** — runs on a self-hosted homelab (Proxmox/LXC + Tailscale + caddy-docker-proxy) with full observability (OTEL → Tempo, Prometheus, Grafana) and post-incident RCAs (`docs/rca/`).

> Shared for evaluation and reference only — see [`LICENSE`](LICENSE).

## Screenshots

<!-- TODO: add a screenshot or short GIF of the running app under docs/assets/ and embed it here, e.g. ![Slackex](docs/assets/chat.png) -->

_A screenshot / short GIF of the running app goes here._

## Reviewer Guide

Short on time? These are the fastest tour of how I work:

| To see… | Open |
|---|---|
| **The deployment story** — homelab, zero-downtime rolling restart, release boot-check, pre-deploy DB backup, Tailscale, GHCR, Caddy | `.github/workflows/ci-deploy.yml` |
| **CI ↔ local parity** — identical format / credo / dialyzer / test gates both places | `.github/workflows/ci-deploy.yml` + `scripts/pre-commit` + the `ci` alias in `mix.exs` |
| **Spec-first thinking** — design + ADRs before code | `docs/feature/incoming-webhooks/design/`, `docs/feature/sous/design/`, `docs/plans/2026-02-27-dm-safety-phase1-plan.md` |
| **How I handle incidents** | `docs/rca/` |
| **The engineering rulebook (AI within rigour)** | `CLAUDE.md` |
| **Tests alongside features** | the Sous slice — e.g. commit `398c34d` commits the module and its test together |
| **A clean domain module** | `lib/slackex/sous.ex` — invariant-documented event sourcing |
| **Architecture overviews** | `docs/architecture/` |

## Running Locally

Requires Docker and the Elixir/Erlang versions pinned in `.tool-versions`.

```bash
docker compose up -d postgres redis   # Postgres (dev) + Redis
mix setup                              # deps, database, assets
mix phx.server                         # http://localhost:4000
```

Tests use a separate database (`docker compose up -d postgres_test redis` then `mix test`).

## Project Shape

- `lib/slackex/` — domain logic and infrastructure (contexts, OTP supervision)
- `lib/slackex_web/` — LiveView UI, router, controllers, channels, MCP integration
- `test/` — 1,600+ automated tests
- `docs/` — specs, ADRs, architecture notes, runbooks, research, and RCAs
- `infra/` — Caddy, OTEL collector, Prometheus, Tempo, and Grafana provisioning
- `.github/workflows/` — CI quality gate + homelab deploy

## Key Docs

- `docs/architecture/README.md` — architecture index
- `docs/engineering-principles.md` — expand/contract migrations, feature-flag lifecycle, deploy-safety rules
- `docs/runbooks/deployment.md` — deployment runbook
- `docs/runbooks/observability.md` — metrics and tracing

## Learn More

- Phoenix: https://www.phoenixframework.org/
- Phoenix Guides: https://hexdocs.pm/phoenix/overview.html
