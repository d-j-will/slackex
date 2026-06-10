defmodule Slackex.TestTeardownSafetyTest do
  @moduledoc """
  Static analysis: no test may touch the database from an `on_exit` callback.

  `on_exit` runs in ExUnit's OnExitHandler process AFTER the test process —
  the sandbox owner — has exited, so any Repo-backed call there (including
  `FunWithFlags.enable/disable`, which uses the Ecto persistence adapter)
  races connection teardown and raises `DBConnection.OwnershipError` on slow
  runners. It passes locally by timing and fails in CI — the worst kind of
  gap in the commit gate.

  Such teardown is also REDUNDANT: sandboxed writes roll back with the
  test's transaction (verified empirically — a flag enabled in one test is
  invisible to the next). Establish state in setup; let the sandbox clean up.

  Also forbids direct `Sandbox.mode/2` calls in test files: `setup_sandbox`
  already provides shared mode (via `start_owner!`) for `async: false` tests
  with a teardown that flushes and stops ChannelServers BEFORE revoking the
  connection. Manual mode juggling re-points ownership at the mortal test pid
  and breaks that ordering ("ChannelServer flush crashed: cannot find
  ownership ... mode :manual").

  For a genuinely DB-free exception the scanner misreads, append
  `# teardown-db-ok` on the offending line.

  Incident: subscribe_bot_test on_exit FunWithFlags.disable — green in two
  local runs and the pre-commit suite, failed CI run 27250196864.
  """

  use ExUnit.Case, async: true

  @test_root Path.expand("..", __DIR__)
  @db_call ~r/\b(?:Repo|ReadRepo)\.\w|\bFunWithFlags\./
  @max_block_lines 15

  test "no test file manipulates the sandbox mode directly" do
    # setup_sandbox (DataCase/ConnCase) already runs async: false tests in
    # shared mode via start_owner!, with a durable owner that survives until
    # ChannelServers are flushed and stopped in its teardown. A manual
    # `Sandbox.mode(repo, {:shared, self()})` re-points ownership at the
    # mortal test pid, and an on_exit reset to :manual runs BEFORE that
    # teardown (LIFO) — yanking DB access from the ChannelServer
    # terminate-flush ("flush crashed: cannot find ownership ... mode
    # :manual"). Don't manage the sandbox in tests; setup_sandbox owns it.
    offenders =
      test_files()
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} ->
          String.contains?(line, "Sandbox.mode(") and
            not String.contains?(line, "teardown-db-ok")
        end)
        |> Enum.map(fn {_line, n} -> {Path.relative_to_cwd(file), n} end)
      end)

    assert offenders == [],
           """
           Test files must not call Ecto.Adapters.SQL.Sandbox.mode/2 —
           setup_sandbox already provides shared mode for async: false tests
           with the correct teardown ordering. Offenders:

           #{Enum.map_join(offenders, "\n", fn {file, line} -> "  #{file}:#{line}" end)}
           """
  end

  test "on_exit callbacks never touch the database" do
    offenders = Enum.flat_map(test_files(), &offending_on_exits/1)

    assert offenders == [],
           """
           on_exit callbacks must not perform DB work (Repo/FunWithFlags) — the
           sandbox owner is already dead when they run, and sandbox rollback makes
           the cleanup redundant anyway. Move state setup into `setup` and delete
           the teardown. Offenders:

           #{Enum.map_join(offenders, "\n", fn {file, line} -> "  #{file}:#{line}" end)}
           """
  end

  defp test_files do
    @test_root
    |> Path.join("**/*_test.exs")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, "test_teardown_safety_test.exs"))
  end

  defp offending_on_exits(file) do
    lines = file |> File.read!() |> String.split("\n")

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, n} ->
      String.contains?(line, "on_exit(") and db_touching_block?(lines, n)
    end)
    |> Enum.map(fn {_line, n} -> {Path.relative_to_cwd(file), n} end)
  end

  defp db_touching_block?(lines, n) do
    block = lines |> Enum.slice(n - 1, @max_block_lines) |> block_until_close()
    block =~ @db_call and not String.contains?(block, "teardown-db-ok")
  end

  # Take lines from the on_exit through the one that closes it (`end)` for
  # multi-line fns; a single-line `on_exit(fn -> ... end)` closes immediately).
  defp block_until_close([first | rest]) do
    if String.contains?(first, "end)") do
      first
    else
      closing = Enum.take_while(rest, &(not String.contains?(&1, "end)")))
      Enum.join([first | closing] ++ [Enum.at(rest, length(closing), "")], "\n")
    end
  end
end
