defmodule Slackex.Chat.Moderation.RulesTest do
  @moduledoc """
  Unit tests for the pure moderation decision core. No database — every case is
  a hand-built `ModerationContext` so the business rules and their thresholds are
  pinned independently of the gather/act orchestration.
  """

  use ExUnit.Case, async: true

  alias Slackex.Chat.Moderation.Rules
  alias Slackex.Chat.Moderation.Rules.{ModerationAction, ModerationContext}

  # A context that passes every pre-flight check, with low counts (no restriction).
  defp ok_context(overrides) do
    base = %{
      reporter_is_self_reporting: false,
      reporter_account_age_days: 10,
      reporter_is_dm_restricted: false,
      reported_user_distinct_report_count: 1,
      reported_user_negative_signals_24h: 1
    }

    struct!(ModerationContext, Map.merge(base, overrides))
  end

  describe "pre-flight rejections" do
    test "self-reporting yields :self_report and no side-effects" do
      action = Rules.evaluate_abuse_report(ok_context(%{reporter_is_self_reporting: true}))

      assert action == %ModerationAction{error: :self_report}
    end

    test "account under 7 days yields :account_too_new" do
      action = Rules.evaluate_abuse_report(ok_context(%{reporter_account_age_days: 6}))

      assert action == %ModerationAction{error: :account_too_new}
    end

    test "dm-restricted reporter yields :dm_restricted" do
      action = Rules.evaluate_abuse_report(ok_context(%{reporter_is_dm_restricted: true}))

      assert action == %ModerationAction{error: :dm_restricted}
    end

    test "self-report takes precedence over account age and dm restriction" do
      action =
        Rules.evaluate_abuse_report(
          ok_context(%{
            reporter_is_self_reporting: true,
            reporter_account_age_days: 0,
            reporter_is_dm_restricted: true
          })
        )

      assert action.error == :self_report
    end

    test "account age is checked before dm restriction" do
      action =
        Rules.evaluate_abuse_report(
          ok_context(%{reporter_account_age_days: 3, reporter_is_dm_restricted: true})
        )

      assert action.error == :account_too_new
    end
  end

  describe "account age boundary" do
    test "exactly 7 days is allowed (not too new)" do
      action = Rules.evaluate_abuse_report(ok_context(%{reporter_account_age_days: 7}))

      assert action.error == nil
      assert action.create_report
    end
  end

  describe "accepted report side-effects" do
    test "low counts: create, auto-block, and increment — but no restriction or flag" do
      action =
        Rules.evaluate_abuse_report(
          ok_context(%{
            reported_user_distinct_report_count: 2,
            reported_user_negative_signals_24h: 2
          })
        )

      assert action == %ModerationAction{
               create_report: true,
               auto_block_user: true,
               increment_report_count: true,
               apply_dm_restriction: false,
               flag_for_admin: false,
               error: nil
             }
    end
  end

  describe "dm-restriction gate (distinct reporters >= 3 OR velocity signals >= 3)" do
    test "3 distinct reporters restricts, with zero velocity signals" do
      action =
        Rules.evaluate_abuse_report(
          ok_context(%{
            reported_user_distinct_report_count: 3,
            reported_user_negative_signals_24h: 0
          })
        )

      assert action.apply_dm_restriction
      refute action.flag_for_admin
    end

    test "3 velocity signals restricts, with only 1 distinct reporter" do
      action =
        Rules.evaluate_abuse_report(
          ok_context(%{
            reported_user_distinct_report_count: 1,
            reported_user_negative_signals_24h: 3
          })
        )

      assert action.apply_dm_restriction
      refute action.flag_for_admin
    end

    test "2 distinct and 2 signals does not restrict (both gates below threshold)" do
      action =
        Rules.evaluate_abuse_report(
          ok_context(%{
            reported_user_distinct_report_count: 2,
            reported_user_negative_signals_24h: 2
          })
        )

      refute action.apply_dm_restriction
    end
  end

  describe "admin-flag gate (distinct reporters >= 5)" do
    test "5 distinct reporters flags for admin and also restricts" do
      action =
        Rules.evaluate_abuse_report(
          ok_context(%{
            reported_user_distinct_report_count: 5,
            reported_user_negative_signals_24h: 0
          })
        )

      assert action.flag_for_admin
      assert action.apply_dm_restriction
    end

    test "4 distinct reporters does not flag for admin" do
      action =
        Rules.evaluate_abuse_report(
          ok_context(%{
            reported_user_distinct_report_count: 4,
            reported_user_negative_signals_24h: 0
          })
        )

      refute action.flag_for_admin
      # 4 >= 3, so DMs are still restricted via the distinct-reporter gate.
      assert action.apply_dm_restriction
    end
  end
end
