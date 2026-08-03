defmodule Slackex.SandboxTeardownOwnerTest do
  @moduledoc """
  The teardown sweep used to die at random, and this is the deterministic
  version of the thing that killed it.

  `DataCase.shutdown_channel_servers/1` mints a short-lived sandbox owner so a
  dying `ChannelServer` has a live connection to flush through. It did that
  with a bare `Sandbox.start_owner!/2`, which **raises** when the calling
  process can already reach the database. When that happened the whole
  `on_exit` blew up, failing whichever test was finishing at the time — and
  because the sweep only runs when a ChannelServer actually survived, it
  surfaced perhaps once per few full runs. With `--max-failures 1` in
  `scripts/pre-commit`, that refuses the commit.

  There is no need to reproduce the timing to test the fix: the failure was
  never really about timing, only reached by it. The state that breaks it can
  be created in one line, which is what these do.
  """
  use Slackex.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Slackex.DataCase

  describe "start_dummy_owner/1 when the caller can already reach the database" do
    test "an allowed process gets a usable answer instead of a raise" do
      # `{:already, :allowed}` — the exact term from the production stack
      # trace. Before the fix this raised MatchError out of on_exit.
      #
      # The allowance has to come from a genuine owner, so mint one in its own
      # process first. (This test runs async: false, so the repo is already in
      # shared mode and `self()` is not the owner — allowing from here answers
      # `:not_found`.)
      owner = Task.async(fn -> Sandbox.start_owner!(Slackex.ReadRepo, shared: false) end)
      owner_pid = Task.await(owner)

      task =
        Task.async(fn ->
          :ok = Sandbox.allow(Slackex.ReadRepo, owner_pid, self())
          DataCase.start_dummy_owner(Slackex.ReadRepo)
        end)

      assert Task.await(task) == :already_connected

      Sandbox.stop_owner(owner_pid)
    end

    test "a process that already checked out gets one too" do
      # The sibling term, `{:already, :owner}`. Same class, same answer —
      # both mean "you already have what you were asking for".
      task =
        Task.async(fn ->
          :ok = Sandbox.checkout(Slackex.Repo)
          DataCase.start_dummy_owner(Slackex.Repo)
        end)

      assert Task.await(task) == :already_connected
    end

    test "a process with no access still gets a real owner to hand out" do
      # The path that always worked, pinned so the rescue cannot quietly
      # swallow the normal case and leave the sweep with no connection.
      task =
        Task.async(fn ->
          case DataCase.start_dummy_owner(Slackex.ReadRepo) do
            {:ok, pid} ->
              alive? = Process.alive?(pid)
              Sandbox.stop_owner(pid)
              {:started, alive?}

            other ->
              other
          end
        end)

      assert Task.await(task) == {:started, true}
    end

    test "an unrelated MatchError is re-raised rather than read as an owner" do
      # The rescue matches on the `{:already, _}` shape specifically. If it
      # ever widens to bare `MatchError`, a genuine failure inside
      # `start_owner!` would be silently reported as "already connected" and
      # the sweep would run with no connection at all.
      assert_raise MatchError, fn ->
        DataCase.start_dummy_owner(:no_such_repo)
      end
    end
  end
end
