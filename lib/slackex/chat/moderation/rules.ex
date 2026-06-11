defmodule Slackex.Chat.Moderation.Rules do
  @moduledoc """
  Pure decision core for abuse-report moderation.

  This module is the "Decide" stage of the Gather → Decide → Act pipeline in
  `Slackex.Chat.Moderation`. It contains **no** database access, no `Ecto`, and
  no `Repo` — only the business rules that turn a fully-gathered
  `ModerationContext` into a `ModerationAction` describing which side-effects the
  orchestrator should perform.

  Keeping these rules pure means they can be exercised in isolation with plain
  structs (no DB fixtures), and the thresholds live in one obvious place.
  """

  alias Slackex.Chat.Moderation.Rules.{ModerationAction, ModerationContext}

  # Reporters whose account is younger than this (in days) cannot file reports.
  @new_account_age_days 7
  # Distinct reporter clusters at/above this restrict the reported user's DMs.
  @report_restrict_threshold 3
  # Distinct reporter clusters at/above this flag the reported user for an admin.
  @report_admin_flag_threshold 5
  # Negative signals within the velocity window at/above this restrict DMs.
  @velocity_signal_threshold 3

  defmodule ModerationContext do
    @moduledoc """
    Everything the rules need to know about a prospective abuse report, gathered
    by the orchestrator before any decision is made.

    The two count fields are *projected* values: they reflect the state of the
    world **after** this report and its auto-block would be applied, so the rules
    can decide on the same numbers the side-effects will produce.
    """

    @enforce_keys [
      :reporter_is_self_reporting,
      :reporter_account_age_days,
      :reporter_is_dm_restricted,
      :reported_user_distinct_report_count,
      :reported_user_negative_signals_24h
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            reporter_is_self_reporting: boolean(),
            reporter_account_age_days: integer(),
            reporter_is_dm_restricted: boolean(),
            reported_user_distinct_report_count: non_neg_integer(),
            reported_user_negative_signals_24h: non_neg_integer()
          }
  end

  defmodule ModerationAction do
    @moduledoc """
    The decision: which side-effects the orchestrator should carry out. When
    `error` is set, no side-effects run and the orchestrator returns the error.
    """

    defstruct create_report: false,
              auto_block_user: false,
              increment_report_count: false,
              apply_dm_restriction: false,
              flag_for_admin: false,
              error: nil

    @type t :: %__MODULE__{
            create_report: boolean(),
            auto_block_user: boolean(),
            increment_report_count: boolean(),
            apply_dm_restriction: boolean(),
            flag_for_admin: boolean(),
            error: atom() | nil
          }
  end

  @doc """
  Evaluates a gathered `ModerationContext` and returns the `ModerationAction`
  to perform.

  Pre-flight rejections short-circuit to an action carrying only an `error`:
    * self-reporting        -> `:self_report`
    * account under 7 days  -> `:account_too_new`
    * reporter dm_restricted -> `:dm_restricted`

  Otherwise the report is accepted: the reported user is auto-blocked, their
  report count is incremented, and — based on the projected counts — their DMs
  may be restricted and/or they may be flagged for an admin.
  """
  @spec evaluate_abuse_report(ModerationContext.t()) :: ModerationAction.t()
  def evaluate_abuse_report(%ModerationContext{reporter_is_self_reporting: true}) do
    %ModerationAction{error: :self_report}
  end

  def evaluate_abuse_report(%ModerationContext{reporter_account_age_days: age_days})
      when age_days < @new_account_age_days do
    %ModerationAction{error: :account_too_new}
  end

  def evaluate_abuse_report(%ModerationContext{reporter_is_dm_restricted: true}) do
    %ModerationAction{error: :dm_restricted}
  end

  def evaluate_abuse_report(%ModerationContext{} = context) do
    %ModerationAction{
      create_report: true,
      auto_block_user: true,
      increment_report_count: true,
      apply_dm_restriction: dm_restriction?(context),
      flag_for_admin: flag_for_admin?(context)
    }
  end

  # DMs are restricted when enough distinct reporters have filed, OR when the
  # reported user has accumulated enough negative signals in the velocity window.
  # These are independent gates: either one alone triggers a restriction.
  defp dm_restriction?(%ModerationContext{} = context) do
    context.reported_user_distinct_report_count >= @report_restrict_threshold or
      context.reported_user_negative_signals_24h >= @velocity_signal_threshold
  end

  defp flag_for_admin?(%ModerationContext{} = context) do
    context.reported_user_distinct_report_count >= @report_admin_flag_threshold
  end
end
