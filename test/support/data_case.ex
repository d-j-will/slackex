# credo:disable-for-this-file Credo.Check.Design.AliasUsage
defmodule Slackex.DataCase do
  # Test support: unchecked boundary (docs-sanctioned pattern for test helpers).
  use Boundary, check: [in: false, out: false]

  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Slackex.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Slackex.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Slackex.DataCase
      import Slackex.TestFactory
      import Slackex.EmbeddingHelpers
    end
  end

  setup tags do
    Slackex.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Slackex.Repo, shared: not tags[:async])
    read_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Slackex.ReadRepo, shared: not tags[:async])

    # Clear shared ETS caches to prevent cross-test contamination.
    # These named tables are owned by application-supervised processes and
    # persist across tests — stale entries cause flaky failures when a
    # ChannelServer picks up incomplete maps from a prior test's writes.
    :ets.delete_all_objects(:slackex_message_cache)

    on_exit(fn ->
      # 1. Gracefully shut down all active ChannelServers BEFORE revoking
      #    the sandbox connection. terminate/2 does a synchronous DB flush —
      #    if the sandbox is revoked first, the flush fails with an EXIT
      #    and causes intermittent test failures.
      _ = shutdown_channel_servers()

      # 2. Drain pipeline listeners — ensures they finish any in-progress
      #    DB queries triggered by ChannelServer's {:messages_persisted, ids}
      #    broadcast via FunWithFlags.
      for name <- [Slackex.Links.LinkPreviewListener, Slackex.Embeddings.PersistenceListener],
          listener_pid = Process.whereis(name),
          listener_pid != nil,
          Process.alive?(listener_pid) do
        try do
          :sys.get_state(listener_pid, 1000)
        catch
          :exit, _ -> :ok
        end
      end

      :ets.delete_all_objects(:slackex_message_cache)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
      Ecto.Adapters.SQL.Sandbox.stop_owner(read_pid)
    end)
  end

  # Terminates all active ChannelServers and waits for each to finish
  # shutdown (including the synchronous DB flush in terminate/2).
  # A 5-second timeout per server catches genuinely stuck processes.
  #
  # Horde.Registry is CRDT-based and eventually consistent, so a server
  # registered in a test's final moments can be missing from a one-shot
  # registry select. We therefore union the registry with the supervisor's
  # own child list (authoritative on a single node) and re-sweep until empty:
  # a survivor's pending :batch_flush (2s timer) would otherwise fire in the
  # inter-test gap under the reverted :manual mode — "ChannelServer flush
  # crashed: cannot find ownership".
  #
  # KNOWN RESIDUAL (log-noise only, slackex bead: teardown-flush deep dive):
  # 2-3 "flush crashed ... mode :manual" lines per full-suite run, emitted
  # DURING this sweep's terminate-flush (probe-verified: crashing pid ==
  # swept pid) despite the sandbox owner being alive. Does not reproduce in
  # isolated file runs — full-suite context only. Benign by construction:
  # the flushed rows belong to the dying test's rolled-back transaction and
  # channel ids are unique per test; the suite stays green.
  defp shutdown_channel_servers(sweeps_left \\ 3) do
    pids = active_channel_servers()

    if pids != [] do
      # Since on_exit runs after the test process exits, the test's Sandbox connection
      # is already revoked and closed. If ChannelServer tries to flush its writes,
      # it will crash with DBConnection.OwnershipError.
      # To fix this without polluting production code, we provide a temporary dummy 
      # Sandbox connection for the teardown flush. Because the test transaction has 
      # rolled back, the flush will safely fail with :target_deleted and cleanly exit.
      dummy_repo = Ecto.Adapters.SQL.Sandbox.start_owner!(Slackex.Repo, shared: false)
      dummy_read = Ecto.Adapters.SQL.Sandbox.start_owner!(Slackex.ReadRepo, shared: false)

      for pid <- pids, Process.alive?(pid) do
        ref = Process.monitor(pid)

        _ =
          try do
            Ecto.Adapters.SQL.Sandbox.allow(Slackex.Repo, dummy_repo, pid)
            Ecto.Adapters.SQL.Sandbox.allow(Slackex.ReadRepo, dummy_read, pid)
            Horde.DynamicSupervisor.terminate_child(Slackex.Messaging.ChannelSupervisor, pid)
          catch
            :exit, _ -> :ok
          end

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end
      end

      Ecto.Adapters.SQL.Sandbox.stop_owner(dummy_repo)
      Ecto.Adapters.SQL.Sandbox.stop_owner(dummy_read)

      if sweeps_left > 1, do: shutdown_channel_servers(sweeps_left - 1)
    end

    :ok
  end

  defp active_channel_servers do
    registered =
      try do
        Horde.Registry.select(Slackex.Messaging.ChannelRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
      catch
        :exit, _ -> []
      end

    supervised =
      try do
        Slackex.Messaging.ChannelSupervisor
        |> Horde.DynamicSupervisor.which_children()
        |> Enum.flat_map(fn
          {_, pid, _, _} when is_pid(pid) -> [pid]
          _ -> []
        end)
      catch
        :exit, _ -> []
      end

    Enum.uniq(registered ++ supervised)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
