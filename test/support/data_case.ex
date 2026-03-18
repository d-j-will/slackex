# credo:disable-for-this-file Credo.Check.Design.AliasUsage
defmodule Slackex.DataCase do
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
      import Slackex.Factory
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
      shutdown_channel_servers()

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
  defp shutdown_channel_servers do
    pids =
      try do
        Horde.Registry.select(Slackex.Messaging.ChannelRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
      catch
        :exit, _ -> []
      end

    for pid <- pids, Process.alive?(pid) do
      ref = Process.monitor(pid)

      try do
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
