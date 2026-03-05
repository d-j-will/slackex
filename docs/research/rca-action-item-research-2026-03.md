# Research: Resolving Open Action Items from v0.5.36-v0.5.43 RCA

**Date:** 2026-03-05
**Scope:** Evidence-based research for P1/P2 action items from `docs/rca/2026-03-05-embedding-cascade-app-crash.md`
**Goal:** Provide actionable, cited solutions for re-enabling BumblebeeClient safely on the current infrastructure

---

## Executive Summary

The RCA identified 7 root causes and 22 action items. P0 items are complete. This research covers the 11 open P1/P2/P3 items, organized into three resolution paths:

1. **Infrastructure hardening** (Proxmox HA, LXC memory, cgroup enforcement, persistent logging)
2. **EXLA memory profiling and optimization** (measure peak, single-node serving, CI inference test)
3. **Alternative embedding strategies** (API-based providers as escape hatch)

**Key finding:** The most practical path to re-enabling semantic search is a combination of single-node Nx.Serving (halving memory), EXLA JIT telemetry measurement, and LXC memory reduction — not Proxmox HA (which requires 3 nodes the infrastructure doesn't have).

---

## 1. Infrastructure Hardening

### 1.1 Proxmox HA Auto-Restart (Action Item #6)

**Finding: Proxmox HA requires a minimum 3-node cluster. Not viable for single-node.**

Proxmox's official documentation states:

> "At least three cluster nodes (to get reliable quorum)" is a mandatory requirement for HA.
> — [Proxmox HA Wiki](https://pve.proxmox.com/wiki/High_Availability)

The current setup is a single Proxmox host. HA is architecturally impossible without adding two more nodes.

**Alternative: Cron-based health monitoring script.**

The Proxmox community consensus for single-node auto-restart is a cron job that checks container status and restarts stopped containers:

```bash
#!/bin/bash
# /root/lxc-watchdog.sh — run via cron every 2 minutes
CTID=100  # Docker host LXC

STATUS=$(pct status $CTID 2>/dev/null | awk '{print $2}')
if [ "$STATUS" = "stopped" ]; then
    logger "LXC $CTID found stopped — auto-restarting"
    pct start $CTID
fi
```

Cron entry: `*/2 * * * * /root/lxc-watchdog.sh`

This handles the "LXC crashed and nobody noticed for hours" scenario. It does NOT handle the case where the LXC is running but Docker/app is unhealthy — that requires external monitoring (action item #8).

**Sources:**
- [Proxmox HA Wiki](https://pve.proxmox.com/wiki/High_Availability)
- [Auto-restart VM after crash — Proxmox Forum](https://forum.proxmox.com/threads/is-there-a-way-to-instruct-proxmox-to-automatically-restart-a-vm-after-a-crash.134358/)
- [Watchdog for standalone hosts — Proxmox Forum](https://forum.proxmox.com/threads/feature-request-watchdog-for-standalone-hosts-or-workaround.141422/)

**Recommendation:** Replace action item #6 with "Cron-based LXC watchdog on Proxmox host" + "External uptime monitoring" (#8). HA is not achievable on current infrastructure.

---

### 1.2 LXC Memory Reduction (Action Item #11)

**Finding: 20GB LXC on ~20GB host is catastrophically overcommitted.**

The RCA identified this but didn't quantify the fix. Here's the math:

| Consumer | Memory |
|----------|--------|
| Proxmox host kernel + services | ~1.5-2 GB |
| pihole LXC (CT 101) | 1 GB (allocated) |
| **Available for Docker host LXC** | **~17-18 GB** |
| **Recommended LXC allocation** | **14-16 GB** |
| **Headroom for kernel/buffers** | **2-4 GB** |

The Proxmox host kernel needs memory for its own operations, ZFS ARC (if used), network buffers, and cgroup accounting overhead. Leaving zero headroom means kernel page allocation failures can crash the entire host — which is exactly what happened 6 times.

**Recommendation:** Set LXC memory to 16GB (from 20GB), leaving 4GB headroom. Verify with `free -h` on the Proxmox host under load.

---

### 1.3 Docker Cgroup Memory Enforcement in Unprivileged LXC (Action Item #12)

**Finding: Docker `mem_limit` enforcement inside unprivileged LXC is unreliable.**

Research from the Proxmox forums shows:

> "Failed to find memory cgroup, you may need to add 'cgroup_memory=1 cgroup_enable=memory' to your linux cmdline."
> — [cgroups not working inside LXC — Proxmox Forum](https://forum.proxmox.com/threads/cgroups-not-working-inside-lxc-containers.93038/)

The core issue: unprivileged LXC containers share the host's kernel and may not have full cgroup delegation. Docker's `mem_limit` uses cgroups v2 `memory.max`. If the LXC doesn't have write access to its cgroup subtree, these limits are silently ignored.

**Verification test:**

```bash
# Inside the LXC, run a container with a known memory limit
docker run --rm -m 256m alpine sh -c 'cat /sys/fs/cgroup/memory.max'
# Expected: 268435456 (256MB in bytes)
# If it shows "max" — limits are NOT enforced

# Alternative: stress test
docker run --rm -m 256m progrium/stress --vm 1 --vm-bytes 512M --timeout 10s
# Expected: OOM kill within Docker
# If the LXC itself crashes instead — limits are NOT enforced
```

**Fix options if limits aren't enforced:**

1. **Enable cgroup delegation** in the LXC config (Proxmox host):
   ```
   # /etc/pve/lxc/100.conf
   lxc.cgroup2.memory.max: 16106127360  # 15GB hard limit
   features: nesting=1
   ```

2. **Switch to a privileged LXC** (not recommended — reduces isolation)

3. **Switch to a VM** (Proxmox staff recommendation for Docker workloads):
   > "Just run it in a Qemu VM... much less of a hassle"

4. **Use BEAM-level memory limits** instead of Docker cgroup limits — `+MBas aof` Erlang VM flag to abort on memory allocation failure, or set `ERL_CRASH_DUMP_BYTES=0` and use `:erlang.system_flag(:max_heap_size, ...)`.

**Recommendation:** Run the verification test first. If limits aren't enforced, set `lxc.cgroup2.memory.max` in the LXC config on the Proxmox host as a hard ceiling, and rely on BEAM-level protections as defense-in-depth.

---

### 1.4 Persistent Kernel Logging (Action Item #13)

**Finding: Straightforward systemd-journald configuration.**

The RCA notes that 6 reboots destroyed all kernel crash evidence because `journald` uses volatile storage by default.

**Fix on the Proxmox host:**

```bash
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
```

Or edit `/etc/systemd/journald.conf`:
```ini
[Journal]
Storage=persistent
SystemMaxUse=500M
```

This ensures `journalctl -k --boot=-1` works after a crash, preserving OOM kill evidence.

**Recommendation:** Apply to the Proxmox host immediately. ~5 minutes, zero risk.

---

### 1.5 External Uptime Monitoring (Action Item #8)

**Finding: Multiple free/low-cost options available.**

| Service | Free Tier | Check Interval | Alerting |
|---------|-----------|----------------|----------|
| UptimeRobot | 50 monitors, 5 min | 5 min | Email, Telegram, Slack, webhook |
| Hetrix Tools | 15 monitors | 1 min | Email, Telegram, Slack |
| Better Uptime | 10 monitors | 3 min | Email, Slack, webhook |

The `/health` endpoint already exists and returns JSON with `node`, `cluster_nodes`, and `cluster_size`. Point a monitor at `https://chat.davewil.dev/health` with an expected status code of 200.

**Recommendation:** UptimeRobot free tier with Telegram alerting. Catches the "site down for hours before anyone notices" failure mode.

---

## 2. EXLA Memory Profiling and Optimization

### 2.1 Measuring Peak EXLA Memory During JIT (Action Item #18)

**Finding: EXLA provides telemetry for timing but not memory. Use BEAM tools.**

EXLA emits `[:exla, :compilation]` telemetry events with timing data:
- `:eval_time` — function-to-XLA computation time
- `:compile_time` — XLA-to-executable compilation time
- `:total_time` — sum of both

These are useful for understanding *when* the spike happens but not *how much memory*.

**Memory measurement approach (run on dev Mac Mini):**

```elixir
# In iex -S mix phx.server

# 1. Baseline memory before any inference
:erlang.memory(:total) |> div(1_048_576) |> IO.inspect(label: "baseline MB")

# 2. Attach telemetry handler to log compilation events
:telemetry.attach("exla-jit", [:exla, :compilation], fn _event, measurements, _meta, _config ->
  IO.inspect(measurements, label: "EXLA JIT")
  :erlang.memory(:total) |> div(1_048_576) |> IO.inspect(label: "post-JIT MB")
end, nil)

# 3. Trigger first inference (this is the JIT spike)
Nx.Serving.batched_run(Slackex.Embeddings.EmbeddingServing, "test sentence")

# 4. Peak memory (check recon if available)
# Or use :erlang.system_info(:allocated_areas) for detailed breakdown
:erlang.memory() |> Enum.map(fn {k, v} -> {k, div(v, 1_048_576)} end) |> IO.inspect(label: "post-inference MB")
```

**For more accurate peak measurement, use `:recon_alloc`:**

```elixir
# Add {:recon, "~> 2.5"} to deps
:recon_alloc.memory(:allocated) |> div(1_048_576) |> IO.inspect(label: "peak allocated MB")
```

**Important:** The peak happens during JIT compilation, not during steady-state inference. The first `batched_run` after BEAM start is the critical measurement point. Subsequent calls reuse the compiled executable.

**Sources:**
- [EXLA v0.10.0 Documentation](https://hexdocs.pm/exla/EXLA.html)
- [Tools to debug Memory issues in Elixir](https://medium.com/@johnjocoo/tools-to-debug-memory-issues-in-elixir-d94f2964f7cd)

**Recommendation:** Measure on the dev Mac Mini with `recon_alloc`. If peak < 1.5GB per container, re-enablement with single-node serving (below) is viable within a 16GB LXC.

---

### 2.2 Single-Node EmbeddingServing (Action Item #17)

**Finding: Nx.Serving is distributed by default. Only start it on one node.**

From the [Nx.Serving documentation](https://hexdocs.pm/nx/Nx.Serving.html):

> "All Nx.Servings are distributed by default. If the current machine does not have an instance of Nx.Serving running, batched_run/3 will automatically look for one in the cluster."

This means: **start `EmbeddingServing` on app1 only, and app2 will automatically route inference requests to app1 over Erlang distribution.** No code changes needed in the calling code — `Nx.Serving.batched_run/2` handles this transparently.

**Implementation:**

```elixir
# In config/prod.exs or runtime.exs
# Set only on app1's environment
config :slackex, :embedding_serving_enabled,
  System.get_env("EMBEDDING_SERVING_ENABLED", "false") == "true"

# In Slackex.Embeddings.Supervisor
def init(_arg) do
  children =
    if Application.get_env(:slackex, :embedding_serving_enabled) do
      [embedding_serving_spec()]
    else
      []
    end

  Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 300)
end
```

```yaml
# docker-compose.prod.yml
services:
  app1:
    environment:
      EMBEDDING_SERVING_ENABLED: "true"
  app2:
    environment:
      EMBEDDING_SERVING_ENABLED: "false"
```

**Memory impact:** This halves the EXLA memory footprint from 2x to 1x. app2 uses zero memory for the model. app1 handles all inference. If app1's serving crashes, app2's Oban workers will snooze (existing `ensure_serving_available` check).

**Sources:**
- [Nx.Serving Documentation](https://hexdocs.pm/nx/Nx.Serving.html)
- [DockYard: Elixir ML Clustering](https://dockyard.com/blog/2024/03/05/elixir-machine-learning-clustering-bumblebee-structured-prompting)

**Recommendation:** This is the single highest-impact change for re-enabling BumblebeeClient. Implement before anything else.

---

### 2.3 CI Test Inference (Action Item #16)

**Finding: Add a post-deploy `batched_run` step to exercise JIT compilation.**

The current CI provisions models via `Bumblebee.load_model/1` + `Bumblebee.load_tokenizer/1` (289MB peak). This does NOT trigger EXLA JIT compilation.

**Required CI step (after container start, before health check):**

```bash
# In ci-deploy.yml, after docker compose up
echo "--- Running test inference to trigger EXLA JIT compilation ---"
docker compose -f docker-compose.prod.yml exec -T app1 \
  bin/slackex eval '
    result = Nx.Serving.batched_run(
      Slackex.Embeddings.EmbeddingServing,
      "CI test inference warmup"
    )
    case result do
      %{embedding: t} ->
        dims = Nx.shape(t) |> elem(0)
        if dims == 384, do: IO.puts("OK: #{dims} dimensions"), else: raise "Wrong dimensions: #{dims}"
      other ->
        raise "Unexpected result: #{inspect(other)}"
    end
  ' < /dev/null 2>&1
echo "--- Test inference complete ---"
```

This ensures:
1. The model loads from cache
2. EXLA JIT compilation completes successfully
3. Output dimensions are correct (384)
4. Peak memory during JIT doesn't crash the container

If this step OOMs, the deploy fails visibly instead of crashing on first user request.

**Recommendation:** Add this step only after single-node serving (#17) is implemented, so only app1 runs inference.

---

## 3. Alternative Embedding Strategies

### 3.1 API-Based Embedding as Escape Hatch

If local Bumblebee remains impractical on the current infrastructure, API-based embedding is a viable alternative that requires zero local memory.

**all-MiniLM-L6-v2 via API:**

| Provider | Price | Notes |
|----------|-------|-------|
| [OpenRouter / DeepInfra](https://openrouter.ai/sentence-transformers/all-minilm-l6-v2) | $0.005/M input tokens | Same model, same 384-dim output, API-compatible |
| [Hugging Face Inference API](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) | Free tier (rate-limited) | Official model host |
| Jina AI | Free tier (1M tokens/month) | jina-embeddings-v3, 1024-dim (would require migration) |

**Cost estimate for Slackex:**
- Average message: ~50 tokens
- 1000 messages/day = 50K tokens/day = 1.5M tokens/month
- At $0.005/M tokens: **~$0.0075/month** (effectively free)
- Even at 10x volume: **~$0.075/month**

**Architecture:** Replace `BumblebeeClient` with an `ApiClient` that calls the embedding API:

```elixir
defmodule Slackex.Embeddings.ApiClient do
  @behaviour Slackex.Embeddings.Client

  @impl true
  def generate(texts) when is_list(texts) do
    # POST to provider API
    # Return {:ok, [%Nx.Tensor{}, ...]} with 384-dim vectors
  end
end
```

The existing client behaviour pattern makes this a drop-in replacement — no changes to Oban workers, search, or the backfill task.

**Trade-offs:**

| Factor | Local (Bumblebee) | API |
|--------|-------------------|-----|
| Memory | ~1-2GB per container | 0 |
| Latency | ~50ms (after JIT) | ~100-200ms (network) |
| Privacy | Full (data never leaves server) | Data sent to provider |
| Cost | Hardware cost only | ~$0.01-0.10/month |
| Reliability | Depends on EXLA/LXC stability | Depends on provider uptime |
| Offline | Works offline | Requires internet |

**Recommendation:** Implement `ApiClient` as a third client option alongside `BumblebeeClient` and `StubClient`. Use it as the production default until local inference is proven stable. The cost is negligible and eliminates the entire EXLA/memory/LXC problem space.

---

## 4. Recommended Resolution Order

Based on effort, impact, and risk:

| Priority | Action | Effort | Impact | Risk |
|----------|--------|--------|--------|------|
| 1 | Persistent kernel logging (#13) | 5 min | Medium | None |
| 2 | External monitoring (#8) | 30 min | High | None |
| 3 | LXC memory reduction (#11) | 10 min | High | Low (reboot required) |
| 4 | Cron-based LXC watchdog (replaces #6) | 15 min | Medium | None |
| 5 | Measure EXLA peak memory (#18) | 1 hour | Critical info | None (dev only) |
| 6 | Verify Docker cgroup enforcement (#12) | 30 min | Critical info | None |
| 7 | Single-node EmbeddingServing (#17) | 1-2 hours | High | Low |
| 8 | CI test inference (#16) | 1 hour | Medium | Low |
| 9 | Integration test for BumblebeeClient (#15) | 2-3 hours | Medium | None |
| 10 | ApiClient escape hatch | 2-3 hours | High | Low |

**Items 1-4** can be done immediately with near-zero risk.
**Item 5** (memory measurement) gates the decision on whether to pursue local inference or API.
**Items 7-9** are the path to re-enabling BumblebeeClient.
**Item 10** is the escape hatch if local inference remains impractical.

---

## 5. Safe Re-enablement Checklist

**Do NOT re-enable BumblebeeClient until ALL of the following are true:**

- [ ] LXC memory reduced to 16GB (#11)
- [ ] Docker cgroup enforcement verified (#12)
- [ ] Persistent kernel logging configured (#13)
- [ ] External monitoring active (#8)
- [ ] EXLA peak memory measured on dev (#18) — must be < 1.5GB
- [ ] Single-node EmbeddingServing implemented (#17) — only app1 runs inference
- [ ] CI test inference step added (#16)
- [ ] Integration test for graceful degradation passes (#15)
- [ ] OTP resilience review completed (P2 #14)
- [ ] Cron-based LXC watchdog active (replaces #6)

---

## Sources

- [Proxmox HA Wiki](https://pve.proxmox.com/wiki/High_Availability) — HA requires 3+ nodes
- [Proxmox Forum: Auto-restart VM after crash](https://forum.proxmox.com/threads/is-there-a-way-to-instruct-proxmox-to-automatically-restart-a-vm-after-a-crash.134358/) — cron-based workaround
- [Proxmox Forum: cgroups in LXC](https://forum.proxmox.com/threads/cgroups-not-working-inside-lxc-containers.93038/) — cgroup enforcement issues
- [Proxmox Forum: Watchdog for standalone hosts](https://forum.proxmox.com/threads/feature-request-watchdog-for-standalone-hosts-or-workaround.141422/) — single-node limitations
- [EXLA v0.10.0 Documentation](https://hexdocs.pm/exla/EXLA.html) — telemetry, memory config
- [Nx.Serving Documentation](https://hexdocs.pm/nx/Nx.Serving.html) — distributed serving, automatic routing
- [DockYard: Elixir ML Clustering](https://dockyard.com/blog/2024/03/05/elixir-machine-learning-clustering-bumblebee-structured-prompting) — single-node inference architecture
- [Elixir Forum: Bumblebee Deployment](https://elixirforum.com/t/server-deployment-considerations-for-bumblebee/52579) — CPU inference viability
- [Elixir Forum: Memory explosion with Nx+EXLA](https://elixirforum.com/t/memory-explosion-when-accessing-a-large-map-while-using-nx-exla/56895) — EXLA memory behavior
- [OpenRouter: all-MiniLM-L6-v2](https://openrouter.ai/sentence-transformers/all-minilm-l6-v2) — API pricing ($0.005/M tokens)
- [Hugging Face: all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) — model documentation
- [BentoML: Best Open-Source Embedding Models 2026](https://www.bentoml.com/blog/a-guide-to-open-source-embedding-models) — model comparison
- [Elephas: Best Embedding Models 2026](https://elephas.app/blog/best-embedding-models) — pricing comparison
- [Tools to debug Memory issues in Elixir](https://medium.com/@johnjocoo/tools-to-debug-memory-issues-in-elixir-d94f2964f7cd) — recon_alloc usage
