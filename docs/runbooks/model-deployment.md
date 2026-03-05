# Model Deployment Discipline

ML models in production require their own deployment discipline — separate from code deployment. A model that loads in dev may fail in production due to memory constraints, JIT compilation costs, or race conditions with workers that consume the serving.

## Pre-deploy model validation

**The CI pipeline must validate models, not just cache files.** The current `ci-deploy.yml` caches model weights via `Bumblebee.load_model` + `Bumblebee.load_tokenizer`, but does not run inference. A cached model that fails at inference time is worse than no model — it passes the smoke test, then crashes on first user action.

Required CI steps for model changes:
1. **Cache model files** to the Docker volume (existing step)
2. **Run a warm-up inference** — execute `Nx.Serving.batched_run` with a test string to trigger EXLA JIT compilation during deploy, not on first user request
3. **Verify output dimensions** — confirm the output vector length matches the expected dimensionality (384 for all-MiniLM-L6-v2)

## Resource awareness

- **Document the model's resource profile** — peak memory during EXLA compilation, resident memory after compilation, CPU usage per inference batch
- **Both app containers load the model independently** — memory cost is doubled. If the host cannot support this, configure only one node to run `EmbeddingServing` (via an env var like `EMBEDDING_SERVING_ENABLED=true`)
- **Set container memory limits** in `docker-compose.prod.yml` once the production resource profile is measured — prevents model loading from OOM-killing unrelated services

## Model change checklist

When changing the model (repo, dimensions, or Bumblebee/EXLA version):
1. Test locally with `iex -S mix phx.server` — verify model loads, inference works, output dimensions match
2. Run `mix slackex.backfill_embeddings` locally — verify batch inference at scale
3. If dimensions change, create a migration to alter the `vector()` column **before** deploying the new model
4. Update the CI warm-up inference step if the model repo or cache path changed
5. After deploy, SSH in and verify: `docker compose exec -T app1 curl -sf http://localhost:4000/health`

## Graceful degradation

If `EmbeddingServing` fails to load or crashes permanently:
- The supervisor dies (isolation via `restart: :temporary` prevents cascade)
- Oban workers snooze their jobs (`{:snooze, 30}`) — no crash, no lost data
- Semantic search returns empty results; text search still works
- Next deploy or manual container restart restores full functionality
