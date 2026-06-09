defmodule Slackex.Docs.ArchitectureDocsContractTest do
  @moduledoc """
  Doc-drift contract tests for `docs/architecture/`.

  The architecture docs make precise, load-bearing factual claims about the
  source (RRF constants, the Snowflake bit layout, Oban queue sizes, the
  un-partitioned `messages` table, HNSW index params, ...). Those claims are
  accurate today but have no enforcement, so they silently rot when the code
  changes. Each test below pins one such claim to its source of truth.

  When one of these fails, the FIX IS TWO-SIDED: either the code changed and a
  doc must be updated, or the doc was wrong. The failure message names the doc
  that must change. Do not just edit the assertion to make it pass.

  Tagged `:contract` so it runs in the existing CI step (`mix test --only
  contract`, .github/workflows/ci-deploy.yml) alongside the other contract
  suites. Pure file/attribute reads — no DB, no network.
  """

  use ExUnit.Case, async: true

  @moduletag :contract

  @repo_root Path.expand("../../..", __DIR__)
  @migrations Path.join(@repo_root, "priv/repo/migrations")

  defp source(relative), do: File.read!(Path.join(@repo_root, relative))

  defp migration_files, do: Path.wildcard(Path.join(@migrations, "*.exs"))

  # --- Search: RRF + thresholds (deep-dive-hybrid-rrf-search.md §5, §6) ---

  describe "hybrid RRF search constants" do
    test "RRF k == 60 (deep-dive-hybrid-rrf-search.md §5.1)" do
      src = source("lib/slackex/search/message_search.ex")

      assert src =~ ~r/@rrf_k\s+60\b/,
             "deep-dive-hybrid-rrf-search.md claims @rrf_k = 60; update the doc if it changed"
    end

    test "default similarity threshold == 0.3 (deep-dive-hybrid-rrf-search.md §6.2)" do
      src = source("lib/slackex/search/message_search.ex")

      assert src =~ ~r/@default_similarity_threshold\s+0\.3\b/,
             "deep-dive-hybrid-rrf-search.md claims a 0.3 similarity threshold"
    end

    test "hybrid task timeout == 5_000ms (deep-dive-hybrid-rrf-search.md §9.1)" do
      src = source("lib/slackex/search/message_search.ex")

      assert src =~ ~r/@hybrid_task_timeout\s+5_000\b/,
             "deep-dive-hybrid-rrf-search.md §9.1 claims a 5s Task.await timeout"
    end

    test "overlap keeps the text struct via Map.put_new over text ++ semantic" do
      # deep-dive-hybrid-rrf-search.md §5.4: the TEXT struct wins on overlap.
      # That claim depends on BOTH facts — Map.put_new (first occurrence wins)
      # AND text_messages coming first in the concat. Pinning only one would
      # let a reorder flip the documented behavior while staying green.
      src = source("lib/slackex/search/message_search.ex")

      assert src =~ ~r/text_messages \+\+ semantic_messages\).*?Map\.put_new/s,
             "§5.4 documents Map.put_new over (text ++ semantic); update the doc if the merge or order changed"
    end
  end

  # --- Snowflake layout (deep-dive-snowflake-partitioning.md, system-landscape.md §7) ---

  describe "Snowflake ID layout" do
    test "bit layout is [41 timestamp][10 node][12 sequence]" do
      src = source("lib/slackex/infrastructure/snowflake.ex")
      assert src =~ ~r/@node_id_bits\s+10\b/, "docs claim 10 node_id bits"
      assert src =~ ~r/@sequence_bits\s+12\b/, "docs claim 12 sequence bits"
    end

    test "epoch is 2025-01-01T00:00:00Z (1_735_689_600_000 ms)" do
      src = source("lib/slackex/infrastructure/snowflake.ex")

      assert src =~ ~r/@epoch\s+1_735_689_600_000\b/,
             "system-landscape.md §7 claims a 2025-01-01 epoch"
    end

    test "acquires a Postgres advisory lock on node_id at startup" do
      src = source("lib/slackex/infrastructure/snowflake.ex")

      assert src =~ "pg_try_advisory_lock",
             "system-landscape.md §7 claims a session-level advisory lock guards node_id uniqueness"
    end
  end

  # --- Messages table is NOT partitioned (data-model-erd.md §1, system-landscape.md §6) ---

  describe "messages table partitioning" do
    test "no migration introduces a PARTITION (claim: messages is a flat table)" do
      offenders =
        migration_files()
        |> Enum.filter(fn f -> File.read!(f) =~ ~r/\bPARTITION\b/i end)
        |> Enum.map(&Path.basename/1)

      assert offenders == [],
             "data-model-erd.md and system-landscape.md state NO table is partitioned, " <>
               "but these migrations mention PARTITION: #{inspect(offenders)}. " <>
               "If partitioning was implemented, update both docs (and the snowflake deep-dive)."
    end
  end

  # --- Embeddings: 384-dim vector + HNSW params (deep-dive-hybrid-rrf-search.md §7) ---

  describe "message_embeddings index" do
    test "current embedding dimension is 384" do
      resize = source("priv/repo/migrations/20260304000000_resize_embeddings_to_384.exs")

      assert resize =~ ~r/vector\(384\)/,
             "deep-dive-hybrid-rrf-search.md §7 claims embeddings were resized to 384 dims"
    end

    test "HNSW index uses m=16, ef_construction=64, vector_cosine_ops" do
      resize = source("priv/repo/migrations/20260304000000_resize_embeddings_to_384.exs")
      assert resize =~ ~r/m\s*=\s*16/, "doc claims HNSW m=16"
      assert resize =~ ~r/ef_construction\s*=\s*64/, "doc claims ef_construction=64"
      assert resize =~ "vector_cosine_ops", "doc claims cosine ops"
    end
  end

  # --- Write-path: epoch fencing (system-landscape.md §4, message-pipeline-and-persistence.md) ---

  test "BatchWriter fences stale writers with SELECT writer_epoch ... FOR UPDATE" do
    src = source("lib/slackex/pipeline/batch_writer.ex")

    assert src =~ ~r/SELECT writer_epoch.*FOR UPDATE/s,
           "system-landscape.md §4 claims row-level writer_epoch FOR UPDATE fencing"
  end

  # --- Oban queues (system-landscape.md §5, background-jobs-and-workers.md) ---

  test "Oban queue concurrency matches the documented table" do
    # Asserts on the merged runtime config rather than regex-over-source:
    # config/test.exs only adds `testing: :inline`, so :queues survives the
    # merge, and equality also catches queues being added or removed.
    queues = :slackex |> Application.get_env(Oban) |> Keyword.fetch!(:queues)

    expected = [
      default: 10,
      notifications: 20,
      embeddings: 5,
      link_previews: 5,
      analytics: 5,
      facets: 3
    ]

    assert Enum.sort(queues) == Enum.sort(expected),
           "background-jobs-and-workers.md / system-landscape.md §5 document the queue table; " <>
             "update both docs if the Oban queues changed"
  end

  # --- Sous tables exist (data-model-erd.md §2.1) ---

  test "Sous owns work_items, decisions, and work_item_events tables" do
    sous = source("priv/repo/migrations/20260527145912_create_sous_tables.exs")

    for table <- ~w(work_items decisions work_item_events) do
      assert sous =~ ~r/create table\(:#{table}/,
             "data-model-erd.md lists :#{table} under the Sous context"
    end
  end

  # --- Toolchain version (deployment-topology.md §3) ---

  test "Elixir/OTP toolchain matches deployment-topology.md" do
    # Anchored to whole lines: a bare substring like "elixir 1.19.2" would
    # still match after a bump to 1.19.20 and silently stop enforcing the doc.
    tv = source(".tool-versions")
    assert tv =~ ~r/^erlang 28\.1\.1$/m, "deployment-topology.md §3 pins OTP 28.1.1"

    assert tv =~ ~r/^elixir 1\.19\.2(-otp-\d+)?$/m,
           "deployment-topology.md §3 pins Elixir 1.19.2"
  end

  # --- Prod embedding client (deep-dive-hybrid-rrf-search.md §9.4) ---

  test "prod embedding client is OpenAIClient (DeepInfra), not Stub/Bumblebee" do
    src = source("config/prod.exs")

    assert src =~ ~r/:embedding_client,\s*Slackex\.Embeddings\.OpenAIClient/,
           "deep-dive-hybrid-rrf-search.md §9.4 states prod uses OpenAIClient against DeepInfra"
  end
end
