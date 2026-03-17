defmodule Slackex.Chat.MessageGroupingTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat.Message
  alias Slackex.Chat.MessageGrouping

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp msg(fields) do
    defaults = %{
      id: System.unique_integer([:positive]),
      sender_id: 1,
      inserted_at: ~U[2026-03-17 14:00:00.000000Z],
      deleted_at: nil,
      parent_message_id: nil,
      grouped: false,
      show_divider: false,
      divider_label: nil
    }

    struct!(Message, Map.merge(defaults, Map.new(fields)))
  end

  defp at(hour, minute) do
    %{~U[2026-03-17 00:00:00.000000Z] | hour: hour, minute: minute}
  end

  defp yesterday_at(hour, minute) do
    %{~U[2026-03-16 00:00:00.000000Z] | hour: hour, minute: minute}
  end

  defp older_at(hour, minute) do
    %{~U[2026-03-15 00:00:00.000000Z] | hour: hour, minute: minute}
  end

  # ---------------------------------------------------------------------------
  # annotate/1
  # ---------------------------------------------------------------------------

  describe "annotate/1" do
    test "empty list returns empty list" do
      assert MessageGrouping.annotate([]) == []
    end

    test "single message is never grouped and has no divider" do
      [result] = MessageGrouping.annotate([msg(inserted_at: at(14, 0))])

      assert result.grouped == false
      assert result.show_divider == false
      assert result.divider_label == nil
    end

    test "first message in a list is never grouped even when same sender follows" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 1, inserted_at: at(14, 1))

      [first, _second] = MessageGrouping.annotate([m1, m2])

      assert first.grouped == false
    end

    test "same sender within 5 minutes → second message is grouped" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 1, inserted_at: at(14, 4))

      [_first, second] = MessageGrouping.annotate([m1, m2])

      assert second.grouped == true
    end

    test "same sender exactly at 5 minutes → not grouped (boundary is exclusive)" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 1, inserted_at: at(14, 5))

      [_first, second] = MessageGrouping.annotate([m1, m2])

      assert second.grouped == false
    end

    test "same sender beyond 5 minutes → not grouped" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 1, inserted_at: at(14, 6))

      [_first, second] = MessageGrouping.annotate([m1, m2])

      assert second.grouped == false
    end

    test "different sender → not grouped" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 2, inserted_at: at(14, 1))

      [_first, second] = MessageGrouping.annotate([m1, m2])

      assert second.grouped == false
    end

    test "previous message is deleted → not grouped" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0), deleted_at: ~U[2026-03-17 14:00:30.000000Z])
      m2 = msg(sender_id: 1, inserted_at: at(14, 1))

      [_first, second] = MessageGrouping.annotate([m1, m2])

      assert second.grouped == false
    end

    test "current message is a thread reply → not grouped" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 1, inserted_at: at(14, 1), parent_message_id: 999)

      [_first, second] = MessageGrouping.annotate([m1, m2])

      assert second.grouped == false
    end

    test "30+ minute gap → show_divider true on second message" do
      m1 = msg(sender_id: 1, inserted_at: at(13, 0))
      m2 = msg(sender_id: 1, inserted_at: at(13, 30))

      [_first, second] = MessageGrouping.annotate([m1, m2])

      assert second.show_divider == true
      assert is_binary(second.divider_label)
    end

    test "small gap (< 30 min) → no divider" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 1, inserted_at: at(14, 29))

      [_first, second] = MessageGrouping.annotate([m1, m2])

      assert second.show_divider == false
      assert second.divider_label == nil
    end

    test "exactly 30 minute gap → show_divider true (boundary is inclusive)" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 1, inserted_at: at(14, 30))

      [_first, second] = MessageGrouping.annotate([m1, m2])

      assert second.show_divider == true
    end

    test "first message never gets a divider even with no predecessor" do
      [result] = MessageGrouping.annotate([msg(inserted_at: at(14, 0))])

      assert result.show_divider == false
    end

    test "divider label for same-day message reads 'Today at HH:MM'" do
      # Use a fixed time that matches today = 2026-03-17
      today_ts = ~U[2026-03-17 14:30:00.000000Z]
      earlier_ts = ~U[2026-03-17 13:00:00.000000Z]

      m1 = msg(inserted_at: earlier_ts)
      m2 = msg(inserted_at: today_ts)

      [_first, second] =
        MessageGrouping.annotate([m1, m2], today: ~D[2026-03-17])

      assert second.divider_label == "Today at 14:30"
    end

    test "divider label for yesterday message reads 'Yesterday at HH:MM'" do
      yesterday_ts = ~U[2026-03-16 09:15:00.000000Z]
      earlier_ts = ~U[2026-03-16 08:00:00.000000Z]

      m1 = msg(inserted_at: earlier_ts)
      m2 = msg(inserted_at: yesterday_ts)

      [_first, second] =
        MessageGrouping.annotate([m1, m2], today: ~D[2026-03-17])

      assert second.divider_label == "Yesterday at 09:15"
    end

    test "divider label for older message reads 'Month Day at HH:MM'" do
      old_ts = ~U[2026-03-15 14:30:00.000000Z]
      earlier_ts = ~U[2026-03-15 13:00:00.000000Z]

      m1 = msg(inserted_at: earlier_ts)
      m2 = msg(inserted_at: old_ts)

      [_first, second] =
        MessageGrouping.annotate([m1, m2], today: ~D[2026-03-17])

      assert second.divider_label == "March 15 at 14:30"
    end

    test "a chain of same-sender messages within 5 min are all grouped after first" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 1, inserted_at: at(14, 1))
      m3 = msg(sender_id: 1, inserted_at: at(14, 2))
      m4 = msg(sender_id: 1, inserted_at: at(14, 3))

      [r1, r2, r3, r4] = MessageGrouping.annotate([m1, m2, m3, m4])

      assert r1.grouped == false
      assert r2.grouped == true
      assert r3.grouped == true
      assert r4.grouped == true
    end

    test "grouping resets after a different sender" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 2, inserted_at: at(14, 1))
      m3 = msg(sender_id: 1, inserted_at: at(14, 2))

      [_r1, r2, r3] = MessageGrouping.annotate([m1, m2, m3])

      assert r2.grouped == false
      # m3 follows m2 (sender 2), not m1, so different sender
      assert r3.grouped == false
    end

    test "grouping resets after a time gap" do
      m1 = msg(sender_id: 1, inserted_at: at(14, 0))
      m2 = msg(sender_id: 1, inserted_at: at(14, 1))
      m3 = msg(sender_id: 1, inserted_at: at(14, 10))

      [_r1, r2, r3] = MessageGrouping.annotate([m1, m2, m3])

      assert r2.grouped == true
      assert r3.grouped == false
    end
  end

  # ---------------------------------------------------------------------------
  # should_group?/2
  # ---------------------------------------------------------------------------

  describe "should_group?/2" do
    test "returns false when last_message is nil" do
      incoming = msg(sender_id: 1, inserted_at: at(14, 0))

      assert MessageGrouping.should_group?(incoming, nil) == false
    end

    test "returns true when all grouping criteria are met" do
      last = msg(sender_id: 1, inserted_at: at(14, 0))
      incoming = msg(sender_id: 1, inserted_at: at(14, 1))

      assert MessageGrouping.should_group?(incoming, last) == true
    end

    test "returns false when senders differ" do
      last = msg(sender_id: 1, inserted_at: at(14, 0))
      incoming = msg(sender_id: 2, inserted_at: at(14, 1))

      assert MessageGrouping.should_group?(incoming, last) == false
    end

    test "returns false when gap exceeds 5 minutes" do
      last = msg(sender_id: 1, inserted_at: at(14, 0))
      incoming = msg(sender_id: 1, inserted_at: at(14, 6))

      assert MessageGrouping.should_group?(incoming, last) == false
    end

    test "returns false when previous message is deleted" do
      last =
        msg(sender_id: 1, inserted_at: at(14, 0), deleted_at: ~U[2026-03-17 14:00:30.000000Z])

      incoming = msg(sender_id: 1, inserted_at: at(14, 1))

      assert MessageGrouping.should_group?(incoming, last) == false
    end

    test "returns false when incoming message is a thread reply" do
      last = msg(sender_id: 1, inserted_at: at(14, 0))
      incoming = msg(sender_id: 1, inserted_at: at(14, 1), parent_message_id: 42)

      assert MessageGrouping.should_group?(incoming, last) == false
    end
  end

  # ---------------------------------------------------------------------------
  # divider_info/2
  # ---------------------------------------------------------------------------

  describe "divider_info/2" do
    test "returns {false, nil} when gap is less than 30 minutes" do
      last = msg(inserted_at: at(14, 0))
      incoming = msg(inserted_at: at(14, 29))

      assert MessageGrouping.divider_info(incoming, last, today: ~D[2026-03-17]) ==
               {false, nil}
    end

    test "returns {true, label} when gap is exactly 30 minutes" do
      last = msg(inserted_at: at(14, 0))
      incoming = msg(inserted_at: at(14, 30))

      {show, label} = MessageGrouping.divider_info(incoming, last, today: ~D[2026-03-17])

      assert show == true
      assert label == "Today at 14:30"
    end

    test "returns {true, label} when gap exceeds 30 minutes" do
      last = msg(inserted_at: yesterday_at(8, 0))
      incoming = msg(inserted_at: yesterday_at(9, 15))

      {show, label} = MessageGrouping.divider_info(incoming, last, today: ~D[2026-03-17])

      assert show == true
      assert label == "Yesterday at 09:15"
    end

    test "returns older date format for messages older than yesterday" do
      last = msg(inserted_at: older_at(13, 0))
      incoming = msg(inserted_at: older_at(14, 30))

      {show, label} = MessageGrouping.divider_info(incoming, last, today: ~D[2026-03-17])

      assert show == true
      assert label == "March 15 at 14:30"
    end

    test "returns {false, nil} when last_message is nil" do
      incoming = msg(inserted_at: at(14, 0))

      assert MessageGrouping.divider_info(incoming, nil, today: ~D[2026-03-17]) ==
               {false, nil}
    end
  end
end
