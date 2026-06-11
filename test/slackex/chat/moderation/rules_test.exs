defmodule Slackex.Chat.Moderation.RulesTest do
  @moduledoc """
  Unit tests for the pure moderation decision core. No database — every case is
  a hand-built `ModerationContext` so the business rules and their thresholds are
  pinned independently of the gather/act orchestration.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

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

  # ──────────────────────────────────────────────────────────────────────────
  # Property-based invariants
  #
  # The example tests above pin specific rows; these properties prove the same
  # rules hold across the *entire* generated input space. `evaluate_abuse_report/1`
  # is pure, so nothing here touches the database — we just feed thousands of
  # random ModerationContexts through the decision core and assert the invariants.
  # ──────────────────────────────────────────────────────────────────────────

  # Random spread across every ModerationContext field. The ranges straddle the
  # decision thresholds (account age 7, restrict/velocity 3, admin flag 5) so each
  # branch of the rules is exercised frequently rather than sampled at the edges.
  defp context_generator do
    gen all(
          self_reporting <- boolean(),
          account_age_days <- integer(0..14),
          dm_restricted <- boolean(),
          distinct_report_count <- integer(0..10),
          negative_signals_24h <- integer(0..10)
        ) do
      %ModerationContext{
        reporter_is_self_reporting: self_reporting,
        reporter_account_age_days: account_age_days,
        reporter_is_dm_restricted: dm_restricted,
        reported_user_distinct_report_count: distinct_report_count,
        reported_user_negative_signals_24h: negative_signals_24h
      }
    end
  end

  # A `check all` *filter clause* gives up after 25 consecutive rejects and raises
  # FilterTooNarrowError — flaky whenever a predicate accepts only a thin slice of
  # the space (a non-self, established, dm-restricted reporter is ~1/8 of it). We
  # filter the generator itself with a generous retry budget instead, so even the
  # narrow slices are sampled deterministically. No DB, so the extra draws are free.
  defp context_where(predicate), do: StreamData.filter(context_generator(), predicate, 500)

  # A report that clears every pre-flight gate: an established, non-self-reporting,
  # unrestricted reporter. Only the projected counts then decide the side-effects.
  defp valid_report?(%ModerationContext{} = ctx) do
    not ctx.reporter_is_self_reporting and
      ctx.reporter_account_age_days >= 7 and
      not ctx.reporter_is_dm_restricted
  end

  describe "property: pre-flight rejections" do
    # Property 1: self-report is the highest-precedence gate, so it must win no
    # matter what the age/restriction/count fields happen to be.
    property "always rejects self-reports, whatever else is true" do
      check all(ctx <- context_where(& &1.reporter_is_self_reporting)) do
        action = Rules.evaluate_abuse_report(ctx)

        assert action.error == :self_report
        refute action.create_report
      end
    end

    # Property 2: account-age is checked *after* self-report, so we exclude
    # self-reporters to isolate the :account_too_new branch.
    property "always rejects new accounts (age < 7), absent a self-report" do
      new_account? = fn ctx ->
        not ctx.reporter_is_self_reporting and ctx.reporter_account_age_days < 7
      end

      check all(ctx <- context_where(new_account?)) do
        action = Rules.evaluate_abuse_report(ctx)

        assert action.error == :account_too_new
        refute action.create_report
      end
    end

    # Property 3: dm-restriction is the last gate, so we exclude the two earlier
    # rejections (self-report, too-new) to isolate the :dm_restricted branch.
    property "always rejects dm-restricted reporters who clear the self-report and age gates" do
      restricted_reporter? = fn ctx ->
        not ctx.reporter_is_self_reporting and
          ctx.reporter_account_age_days >= 7 and
          ctx.reporter_is_dm_restricted
      end

      check all(ctx <- context_where(restricted_reporter?)) do
        action = Rules.evaluate_abuse_report(ctx)

        assert action.error == :dm_restricted
        refute action.create_report
      end
    end
  end

  describe "property: accepted reports" do
    # Property 4: clearing all three gates always produces the baseline side-effects.
    property "a report clearing every gate is always acted on (create + auto-block + increment)" do
      check all(ctx <- context_where(&valid_report?/1)) do
        action = Rules.evaluate_abuse_report(ctx)

        assert action.error == nil
        assert action.create_report
        assert action.auto_block_user
        assert action.increment_report_count
      end
    end

    # Property 5: among valid reports, >= 5 distinct reporters always flags for an admin.
    property "valid report with >= 5 distinct reporters is flagged for an admin" do
      five_distinct? = fn ctx ->
        valid_report?(ctx) and ctx.reported_user_distinct_report_count >= 5
      end

      check all(ctx <- context_where(five_distinct?)) do
        action = Rules.evaluate_abuse_report(ctx)

        assert action.flag_for_admin
      end
    end

    # Property 6: among valid reports, the two restriction gates are independent —
    # either distinct reporters >= 3 OR velocity signals >= 3 must restrict DMs.
    property "valid report restricts DMs when distinct >= 3 OR velocity signals >= 3" do
      trips_restriction? = fn ctx ->
        valid_report?(ctx) and
          (ctx.reported_user_distinct_report_count >= 3 or
             ctx.reported_user_negative_signals_24h >= 3)
      end

      check all(ctx <- context_where(trips_restriction?)) do
        action = Rules.evaluate_abuse_report(ctx)

        assert action.apply_dm_restriction
      end
    end
  end
end
