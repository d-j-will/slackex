defmodule SlackexWeb.ChatLive.CatchupTest do
  use ExUnit.Case, async: true

  alias SlackexWeb.ChatLive.Catchup

  describe "merge_unread/2" do
    test "overwrites existing channel_counts with catchup values" do
      existing = %{channel_counts: %{1 => 0, 2 => 5}, dm_counts: %{}}

      catchup = %{
        channels: [
          %{
            channel_id: 1,
            unread_count: 3,
            channel_name: "general",
            channel_slug: "general",
            recent_messages: []
          }
        ],
        timestamp: DateTime.utc_now()
      }

      merged = Catchup.merge_unread(existing, catchup)
      assert merged.channel_counts[1] == 3
      # Channels not in the catchup payload keep their existing count
      assert merged.channel_counts[2] == 5
      # dm_counts are left untouched
      assert merged.dm_counts == %{}
    end

    test "adds brand-new channel ids found in catchup" do
      existing = %{channel_counts: %{}, dm_counts: %{}}

      catchup = %{
        channels: [
          %{
            channel_id: 99,
            unread_count: 7,
            channel_name: "new",
            channel_slug: "new",
            recent_messages: []
          }
        ],
        timestamp: DateTime.utc_now()
      }

      merged = Catchup.merge_unread(existing, catchup)
      assert merged.channel_counts[99] == 7
    end

    test "empty channels list leaves existing untouched" do
      existing = %{channel_counts: %{1 => 2}, dm_counts: %{3 => 4}}
      catchup = %{channels: [], timestamp: DateTime.utc_now()}
      assert Catchup.merge_unread(existing, catchup) == existing
    end
  end

  describe "summary/1" do
    test "sums unread_count across channels with pluralization" do
      catchup = %{
        channels: [
          %{
            channel_id: 1,
            unread_count: 3,
            channel_name: "a",
            channel_slug: "a",
            recent_messages: []
          },
          %{
            channel_id: 2,
            unread_count: 1,
            channel_name: "b",
            channel_slug: "b",
            recent_messages: []
          }
        ],
        timestamp: DateTime.utc_now()
      }

      assert Catchup.summary(catchup) == "4 new messages while you were away"
    end

    test "singular form when total is exactly 1" do
      catchup = %{
        channels: [
          %{
            channel_id: 1,
            unread_count: 1,
            channel_name: "a",
            channel_slug: "a",
            recent_messages: []
          }
        ],
        timestamp: DateTime.utc_now()
      }

      assert Catchup.summary(catchup) == "1 new message while you were away"
    end

    test "returns nil when total is 0" do
      catchup = %{
        channels: [
          %{
            channel_id: 1,
            unread_count: 0,
            channel_name: "a",
            channel_slug: "a",
            recent_messages: []
          }
        ],
        timestamp: DateTime.utc_now()
      }

      assert Catchup.summary(catchup) == nil
    end

    test "returns nil when channels list is empty" do
      assert Catchup.summary(%{channels: [], timestamp: DateTime.utc_now()}) == nil
    end
  end
end
