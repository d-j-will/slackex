---
name: warn-docker-latest-tag
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: docker-compose.*\.yml$
  - field: new_text
    operator: regex_match
    pattern: "image:.*:latest"
---

⚠️ **`:latest` tag detected in Docker Compose file**

You are using an unpinned `:latest` tag for a Docker image. Major version changes break configs silently — there is no test to catch a YAML schema change in a Docker image.

**What to do:**
1. Check the current stable version on Docker Hub or the image registry
2. Pin to a specific version tag (e.g., `grafana/tempo:2.7.2` not `grafana/tempo:latest`)
3. Document the pinned version and why in `docs/runbooks/observability.md` § "Infrastructure image versions"

**Why this matters:**
- Observability v1: `:latest` pulled Tempo v3 which broke the config schema — removed `compactor` and `storage.block` fields that v2 configs depend on. Crash-looped until pinned to `2.7.2`.
- There is no CI test for Docker image config schema compatibility. Pinning is the only defence.

See CLAUDE.md § "Library Documentation Verification" and `docs/runbooks/observability.md` § "Infrastructure image versions".
