defmodule Slackex.Embeddings.SupervisorTest do
  use ExUnit.Case, async: true

  alias Slackex.Embeddings.Supervisor, as: EmbeddingSupervisor

  describe "init/1 spec verification" do
    test "uses :one_for_one strategy" do
      assert {:ok, {flags, _children}} = EmbeddingSupervisor.init([])
      assert flags.strategy == :one_for_one
    end

    test "limits restarts to 5 per 300 seconds" do
      assert {:ok, {flags, _children}} = EmbeddingSupervisor.init([])
      assert flags.intensity == 5
      assert flags.period == 300
    end

    test "supervises EmbeddingServing as sole child" do
      assert {:ok, {_flags, children}} = EmbeddingSupervisor.init([])
      assert length(children) == 1

      [child_spec] = children
      assert child_spec.id == Slackex.Embeddings.EmbeddingServing
    end
  end

  describe "crash isolation" do
    test "supervisor survives child crash and restarts it" do
      # Start a standalone supervisor with same flags but a simple Agent child
      # to avoid needing Bumblebee/Nx in the test environment.
      child_spec = %{
        id: :test_agent,
        start: {Agent, :start_link, [fn -> :ok end, [name: :embed_sup_test_agent]]}
      }

      {:ok, sup} =
        Supervisor.start_link([child_spec],
          strategy: :one_for_one,
          max_restarts: 3,
          max_seconds: 60
        )

      [{:test_agent, child_pid, :worker, [Agent]}] = Supervisor.which_children(sup)
      assert Process.alive?(child_pid)

      # Crash the child
      Process.exit(child_pid, :kill)
      # Brief wait for restart
      Process.sleep(50)

      # Supervisor is still alive
      assert Process.alive?(sup)

      # Child was restarted with a new pid
      [{:test_agent, new_pid, :worker, [Agent]}] = Supervisor.which_children(sup)
      assert Process.alive?(new_pid)
      assert new_pid != child_pid

      Supervisor.stop(sup)
    end

    test "exceeding max_restarts kills the sub-supervisor but not the app supervisor" do
      # Trap exits so the supervisor's death doesn't crash the test process
      Process.flag(:trap_exit, true)

      child_spec = %{
        id: :crasher,
        start: {Agent, :start_link, [fn -> :ok end]},
        restart: :permanent
      }

      {:ok, sup} =
        Supervisor.start_link([child_spec],
          strategy: :one_for_one,
          max_restarts: 2,
          max_seconds: 60
        )

      ref = Process.monitor(sup)

      # Crash the child repeatedly to exceed max_restarts
      for _ <- 1..3 do
        case Supervisor.which_children(sup) do
          [{:crasher, pid, _, _}] when is_pid(pid) ->
            Process.exit(pid, :kill)
            Process.sleep(20)

          _ ->
            :ok
        end
      end

      # The sub-supervisor should die
      assert_receive {:DOWN, ^ref, :process, ^sup, _reason}, 1000

      # The main application supervisor is unaffected
      assert Process.alive?(Process.whereis(Slackex.Supervisor))
    end
  end

  describe "application integration" do
    test "Embeddings.Supervisor is NOT in the running tree (test uses StubClient)" do
      children =
        Slackex.Supervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

      refute Slackex.Embeddings.Supervisor in children
      refute Slackex.Embeddings.EmbeddingServing in children
    end

    test "maybe_embedding_serving/1 returns Supervisor with temporary restart for BumblebeeClient" do
      original = Application.get_env(:slackex, :embedding_client)
      Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.BumblebeeClient)

      on_exit(fn -> Application.put_env(:slackex, :embedding_client, original) end)

      assert [spec] = Slackex.Application.maybe_embedding_serving([])
      assert spec.id == Slackex.Embeddings.Supervisor
      assert spec.restart == :temporary
    end
  end
end
