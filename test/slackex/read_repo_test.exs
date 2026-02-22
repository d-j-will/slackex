defmodule Slackex.ReadRepoTest do
  use Slackex.DataCase, async: false

  import Bitwise

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias Slackex.Chat
  alias Slackex.ReadRepo
  alias Slackex.ReadRepo.LagMonitor

  # Snowflake epoch: 2025-01-01T00:00:00Z in ms (matches Snowflake module @epoch)
  @snowflake_epoch 1_735_689_600_000
  # Timestamp occupies bits [63:22], shift = node_id_bits(10) + seq_bits(12) = 22
  @timestamp_shift 22
  # Lag flag key (must match LagMonitor's @lag_key)
  @lag_key :slackex_read_repo_lag_exceeded
  # No-replica flag key (must match LagMonitor's @no_replica_key)
  @no_replica_key :slackex_read_repo_no_replica

  # Temporarily pretend a replica is configured for routing tests.
  # Restores the original value on test exit.
  defp with_replica_mode do
    :persistent_term.put(@no_replica_key, false)
    on_exit(fn -> :persistent_term.put(@no_replica_key, true) end)
  end

  defp make_snowflake(unix_ms) do
    (unix_ms - @snowflake_epoch) <<< @timestamp_shift
  end

  # ---------------------------------------------------------------------------
  # ReadRepo basics
  # ---------------------------------------------------------------------------

  describe "ReadRepo basics" do
    test "ReadRepo can execute queries against the database" do
      assert {:ok, %{rows: [[1]]}} = EctoSQL.query(ReadRepo, "SELECT 1", [])
    end

    test "read_repo/0 returns Slackex.Repo in no-replica mode (test env)" do
      assert LagMonitor.no_replica?()
      assert ReadRepo.read_repo() == Slackex.Repo
    end

    test "read_repo/0 returns Slackex.ReadRepo when replica is configured" do
      with_replica_mode()
      assert ReadRepo.read_repo() == Slackex.ReadRepo
    end
  end

  # ---------------------------------------------------------------------------
  # repo_for_age/1 routing
  # ---------------------------------------------------------------------------

  describe "repo_for_age/1 routing" do
    test "repo_for_age(:recent) always returns primary Slackex.Repo" do
      assert LagMonitor.repo_for_age(:recent) == Slackex.Repo
    end

    test "repo_for_age/1 returns Slackex.Repo for recent Snowflake IDs (within 30s threshold)" do
      five_seconds_ago = System.os_time(:millisecond) - 5_000
      recent_id = make_snowflake(five_seconds_ago)

      assert LagMonitor.repo_for_age(recent_id) == Slackex.Repo
    end

    test "repo_for_age/1 returns Repo for old Snowflake IDs in no-replica mode" do
      two_hours_ago = System.os_time(:millisecond) - 2 * 60 * 60 * 1_000
      old_id = make_snowflake(two_hours_ago)

      assert LagMonitor.no_replica?()
      assert LagMonitor.repo_for_age(old_id) == Slackex.Repo
    end

    test "repo_for_age/1 returns ReadRepo for old Snowflake IDs when replica configured and no lag" do
      with_replica_mode()
      two_hours_ago = System.os_time(:millisecond) - 2 * 60 * 60 * 1_000
      old_id = make_snowflake(two_hours_ago)

      refute LagMonitor.lag_exceeded?()
      assert LagMonitor.repo_for_age(old_id) == Slackex.ReadRepo
    end

    test "repo_for_age/1 falls back to primary Slackex.Repo when lag is exceeded" do
      :persistent_term.put(@lag_key, true)
      on_exit(fn -> :persistent_term.put(@lag_key, false) end)

      two_hours_ago = System.os_time(:millisecond) - 2 * 60 * 60 * 1_000
      old_id = make_snowflake(two_hours_ago)

      assert LagMonitor.repo_for_age(old_id) == Slackex.Repo
    end

    test "ReadRepo.repo_for_age/1 delegates correctly to LagMonitor" do
      assert ReadRepo.repo_for_age(:recent) == Slackex.Repo

      # In no-replica mode, old IDs still route to Repo
      two_hours_ago = System.os_time(:millisecond) - 2 * 60 * 60 * 1_000
      old_id = make_snowflake(two_hours_ago)
      assert ReadRepo.repo_for_age(old_id) == Slackex.Repo

      # With replica configured, old IDs route to ReadRepo
      with_replica_mode()
      assert ReadRepo.repo_for_age(old_id) == Slackex.ReadRepo
    end

    test "ReadRepo.lag_exceeded?/0 delegates correctly to LagMonitor" do
      assert ReadRepo.lag_exceeded?() == LagMonitor.lag_exceeded?()
    end
  end

  # ---------------------------------------------------------------------------
  # Lag detection
  # ---------------------------------------------------------------------------

  describe "lag detection" do
    test "LagMonitor process is running and registered" do
      assert is_pid(Process.whereis(Slackex.ReadRepo.LagMonitor))
    end

    test "lag_exceeded?() returns false in no-replica mode (test env)" do
      assert LagMonitor.lag_exceeded?() == false
    end

    test "lag_exceeded?() reflects the persistent_term value" do
      :persistent_term.put(@lag_key, true)
      on_exit(fn -> :persistent_term.put(@lag_key, false) end)

      assert LagMonitor.lag_exceeded?() == true
    end

    test "perform_lag_check/0 handles pg_last_xact_replay_timestamp NULL without crashing" do
      # In test env, ReadRepo points to the primary PostgreSQL instance.
      # pg_last_xact_replay_timestamp() on a primary returns NULL.
      # The check should handle this gracefully and set lag_exceeded to true.
      on_exit(fn -> :persistent_term.put(@lag_key, false) end)

      assert :ok == LagMonitor.perform_lag_check()

      # After NULL result, lag is set exceeded (conservative fallback)
      assert LagMonitor.lag_exceeded?() == true
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry events
  # ---------------------------------------------------------------------------

  describe "telemetry events" do
    test "lag_null_standby telemetry event is emitted when replay timestamp is NULL" do
      # In test env, pg_last_xact_replay_timestamp() returns NULL (primary, not standby).
      # perform_lag_check should emit [:slackex, :read_repo, :lag_null_standby].
      test_pid = self()

      :telemetry.attach(
        "test-lag-null-standby",
        [:slackex, :read_repo, :lag_null_standby],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-lag-null-standby")
        :persistent_term.put(@lag_key, false)
      end)

      LagMonitor.perform_lag_check()

      assert_receive {:telemetry, [:slackex, :read_repo, :lag_null_standby], %{}, _}
    end

    test "lag_fallback telemetry handler receives correctly shaped events" do
      # Verify the telemetry handler contract: the event carries lag_seconds float.
      test_pid = self()

      :telemetry.attach(
        "test-lag-fallback-shape",
        [:slackex, :read_repo, :lag_fallback],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-lag-fallback-shape") end)

      :telemetry.execute([:slackex, :read_repo, :lag_fallback], %{lag_seconds: 7.3}, %{})

      assert_receive {:telemetry, [:slackex, :read_repo, :lag_fallback], %{lag_seconds: 7.3},
                      _metadata}
    end
  end

  # ---------------------------------------------------------------------------
  # Chat context integration
  # ---------------------------------------------------------------------------

  describe "Chat context integration via ReadRepo" do
    test "list_user_channels/1 returns channels the user is subscribed to" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "user-channels-read-replica"})

      channels = Chat.list_user_channels(user.id)
      assert Enum.any?(channels, &(&1.id == channel.id))
    end

    test "list_user_channels/1 does not return channels user is not subscribed to" do
      user1 = insert(:user)
      user2 = insert(:user)
      {:ok, _channel} = Chat.create_channel(user1.id, %{name: "user1-only-channel"})

      assert Chat.list_user_channels(user2.id) == []
    end

    test "list_public_channels/0 returns all public channels" do
      user = insert(:user)
      {:ok, public_channel} = Chat.create_channel(user.id, %{name: "public-replica-channel"})

      channels = Chat.list_public_channels()
      assert Enum.any?(channels, &(&1.id == public_channel.id))
    end

    test "list_public_channels/0 excludes private channels" do
      user = insert(:user)

      {:ok, _private} =
        Chat.create_channel(user.id, %{name: "private-skip-replica", is_private: true})

      channels = Chat.list_public_channels()
      refute Enum.any?(channels, & &1.is_private)
    end

    test "list_messages/2 without before_id returns recent channel messages" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "messages-recent-replica"})
      {:ok, msg} = Chat.send_message(channel.id, user.id, "Hello replica")

      messages = Chat.list_messages(channel.id)
      assert Enum.any?(messages, &(&1.id == msg.id))
    end

    test "list_messages/2 with before_id filters messages correctly" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "messages-before-replica"})
      {:ok, msg1} = Chat.send_message(channel.id, user.id, "First")
      {:ok, msg2} = Chat.send_message(channel.id, user.id, "Second")
      {:ok, msg3} = Chat.send_message(channel.id, user.id, "Third")

      messages = Chat.list_messages(channel.id, before: msg3.id)
      ids = Enum.map(messages, & &1.id)

      assert msg1.id in ids
      assert msg2.id in ids
      refute msg3.id in ids
    end

    test "list_messages/2 with old before_id routes through Repo in no-replica mode" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "messages-old-cursor"})
      {:ok, msg1} = Chat.send_message(channel.id, user.id, "Old page first")
      {:ok, msg2} = Chat.send_message(channel.id, user.id, "Old page second")

      # In no-replica mode, even old IDs route through primary Repo
      two_hours_ago = System.os_time(:millisecond) - 2 * 60 * 60 * 1_000
      old_cursor = make_snowflake(two_hours_ago)
      assert LagMonitor.repo_for_age(old_cursor) == Slackex.Repo

      # list_messages with an ID before all current messages returns empty
      messages = Chat.list_messages(channel.id, before: old_cursor)
      assert messages == []

      # Sanity: normal query returns both messages
      all_messages = Chat.list_messages(channel.id)
      ids = Enum.map(all_messages, & &1.id)
      assert msg1.id in ids
      assert msg2.id in ids
    end

    test "list_active_channels/1 returns channels with recent messages" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "active-channel-replica"})
      {:ok, _msg} = Chat.send_message(channel.id, user.id, "Active!")

      since = DateTime.add(DateTime.utc_now(), -60, :second)
      active = Chat.list_active_channels(since: since)
      assert Enum.any?(active, &(&1.id == channel.id))
    end
  end
end
