# Research: AI Model Opportunities for Slackex

**Date:** 2026-03-05
**Context:** Embedding pipeline live on DeepInfra (v0.5.44). Configurable OpenAIClient pattern established. Evaluating additional models to enhance the chat experience.
**Status:** Prioritized, ready for implementation planning

---

## Opportunity Map

### 1. Search Reranking — improve search result quality

**What:** After hybrid search (RRF) retrieves ~20 candidates, a cross-encoder reranker scores query-document pairs more accurately than bi-encoder cosine similarity. Particularly effective for short queries against short messages where keyword overlap is sparse.

**Models:**
| Model | Provider | Price | Notes |
|-------|----------|-------|-------|
| `bge-reranker-v2-m3` | DeepInfra | $0.005/M tokens | Multilingual, strong on short text |
| `jina-reranker-v2` | Jina | Free (10M tokens/signup) | 100 RPM free tier |

**Integration:** New `RerankClient` behaviour + configurable API client (same pattern as embeddings). Called after search retrieval, before returning results to the UI. ~1K tokens per search query.

**Estimated cost:** ~$0.001/month at current usage. Effectively free.

**Priority:** High — low effort, immediately improves existing feature.

---

### 2. Channel Summarization — "catch me up"

**What:** Summarize recent channel activity for users who've been away. "What happened in #general since Monday?" Feed recent messages to an LLM, get a structured summary with key decisions, action items, and topics.

**Models:**
| Model | Provider | Price (input/output) | Notes |
|-------|----------|---------------------|-------|
| `gemma-3-4b-it` | DeepInfra | $0.02/$0.04 per M tokens | Good quality, very cheap |
| `llama-3.1-8b-instant` | Groq | $0.05/$0.08 per M tokens | Extremely fast (~500 tok/s) |
| `gemini-2.0-flash` | Google | $0.10/$0.40 per M tokens | Generous free tier, good quality |
| `claude-haiku-4-5` | Anthropic | $0.80/$4.00 per M tokens | Best quality, more expensive |

**Integration:** New `LLMClient` behaviour with `summarize/2`, `complete/2` callbacks. Configurable provider via `:llm_api` config (same pattern as `:embedding_api`). UI: button in channel header "Summarize since [date picker]". Async Oban job for generation.

**Estimated cost:** 50 messages ≈ 2K tokens input + 200 tokens output. At Gemma-3 rates: ~$0.00005 per summary. Even 100 summaries/day = $0.15/month.

**Priority:** High — killer feature for chat apps, unlocks RAG too (same LLM).

---

### 3. RAG — Q&A over chat history

**What:** "When did we decide on the database schema?" → search retrieves relevant messages → LLM synthesizes an answer with citations (message links). Builds on existing embedding search + a cheap LLM.

**Models:** Same as summarization (shared `LLMClient`).

**Integration:** Extend search UI with "Ask" mode alongside existing "Best match" / "Exact words" / "Meaning" modes. Pipeline: query → embedding search → top-K retrieval → rerank (if available) → LLM generates answer with message citations. Oban job for async generation, LiveView streams the result.

**Estimated cost:** ~5K tokens per RAG query (context + answer). At Gemma-3 rates: ~$0.0001 per query. Negligible.

**Dependency:** Requires summarization LLM (shared model). Benefits from reranking (better context selection).

**Priority:** High — natural extension of existing search. Same LLM serves both this and summarization.

---

### 4. Content Moderation / Toxicity Detection

**What:** Flag toxic, abusive, or inappropriate messages for review. Essential for a public-facing chat service. Can auto-hide flagged messages pending moderator review, or show warnings.

**Models:**
| Model | Provider | Price | Notes |
|-------|----------|-------|-------|
| `unitary/toxic-bert` | HF Inference | Free tier | Multi-label toxicity (toxic, severe_toxic, obscene, threat, insult, identity_hate) |
| `facebook/roberta-hate-speech-dynabench-r4` | HF Inference | Free tier | Binary hate speech detection |
| `OpenAI Moderation` | OpenAI | Free (with any API key) | Multi-category, no token cost |
| `Perspective API` | Google/Jigsaw | Free (QPS limits) | Industry standard for comment moderation |

**Integration:** New `ModerationClient` behaviour with `classify/1` returning `{:ok, %{toxic: float, ...}}`. Run inline on message send (low-latency classification models are <50ms). If score > threshold: flag for review, optionally auto-hide. Moderator UI at `/admin/moderation` showing flagged messages with approve/remove actions.

**Estimated cost:** Free (HF free tier or OpenAI moderation endpoint).

**Priority:** Critical for public service — must-have before opening to untrusted users.

---

### 5. Translation — multilingual chat

**What:** Auto-detect message language and offer one-click translation. Or auto-translate for users who set a preferred language.

**Models:**
| Model | Provider | Price | Notes |
|-------|----------|-------|-------|
| `facebook/nllb-200-distilled-600M` | HF Inference | Free tier | 200 languages, good quality |
| Cheap LLMs (Gemma, Llama) | Various | Same as summarization | Can translate as a prompt task |
| `DeepL API Free` | DeepL | Free (500K chars/month) | Best quality for European languages |

**Integration:** Language detection on message save (lightweight, can use `lingua` Elixir library for local detection). Translation on demand (click "Translate" on a message) or auto-translate based on user preference. Cache translations in a `message_translations` table to avoid re-translating.

**Estimated cost:** Free tier covers moderate usage. DeepL free: 500K chars ≈ ~12K messages/month.

**Priority:** Medium — valuable for international communities but not blocking for initial launch.

---

## Implementation Order

```
Phase 1: Moderation (P0 for public service)
  └── ModerationClient behaviour + inline classification on message send
  └── Admin moderation UI
  └── Auto-hide + moderator review workflow

Phase 2: LLM Foundation (unlocks summarization + RAG)
  └── LLMClient behaviour + configurable provider
  └── Shared prompt templates

Phase 3: Channel Summarization
  └── "Catch me up" UI in channel header
  └── Oban job for async generation
  └── Summary display component

Phase 4: RAG / Q&A
  └── "Ask" search mode
  └── Context retrieval + reranking + LLM answer
  └── Citation linking to source messages

Phase 5: Search Reranking
  └── RerankClient behaviour
  └── Post-retrieval reranking in search pipeline
  (Can be done earlier if quick — low effort)

Phase 6: Translation
  └── Language detection
  └── On-demand translation UI
  └── message_translations cache table
```

**Shared infrastructure:** All API-based models follow the same configurable client pattern established by `OpenAIClient` in v0.5.44: behaviour module + config-driven URL/model/key + Oban jobs for async work.

---

## Cost Summary (estimated monthly at moderate usage)

| Feature | Model | Monthly cost |
|---------|-------|-------------|
| Embeddings (live) | all-MiniLM-L6-v2 via DeepInfra | ~$0.001 |
| Reranking | bge-reranker-v2-m3 | ~$0.001 |
| Summarization | Gemma-3-4b-it | ~$0.01 |
| RAG | (shared with summarization) | ~$0.01 |
| Moderation | HF free tier or OpenAI moderation | $0.00 |
| Translation | NLLB-200 via HF or DeepL free | $0.00 |
| **Total** | | **~$0.02/month** |

Even at 10x scale, total AI costs would be under $0.25/month.
