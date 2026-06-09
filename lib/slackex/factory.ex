defmodule Slackex.Factory do
  @moduledoc """
  Context for the dark factory pipeline. Manages factory runs through their
  lifecycle: queued -> implementing -> awaiting_verification -> verifying_tier2
  -> completed.

  All state transitions are enforced here. MCP tools delegate to this module.
  """

  use Boundary,
    deps: [Slackex.Accounts, Slackex.Chat, Slackex.Messaging],
    exports: [ChannelNotifier, LifecycleWorker]

  import Ecto.Query

  alias Slackex.Factory.{Event, Run}
  alias Slackex.Repo

  @terminal_statuses ~w(completed needs_review cancelled)
  @token_bytes 16

  # -- Queue -----------------------------------------------------------------

  def queue_run(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:run, Run.queue_changeset(%Run{}, attrs))
    |> Ecto.Multi.insert(:event, fn %{run: run} ->
      Event.changeset(%Event{}, %{
        factory_run_id: run.id,
        event_type: "status_change",
        to_status: "queued",
        message: "Run queued for #{run.spec_path}"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: run}} ->
        broadcast_update(run)
        {:ok, run}

      {:error, :run, changeset, _} ->
        {:error, changeset}
    end
  end

  # -- List ------------------------------------------------------------------

  def list_pending(bot_user_id) do
    from(r in Run,
      where: r.queued_by_id == ^bot_user_id and r.status == "queued",
      order_by: [asc: r.inserted_at],
      limit: 5
    )
    |> Repo.all()
  end

  def list_pending_verification(bot_user_id) do
    from(r in Run,
      where: r.queued_by_id == ^bot_user_id and r.status == "awaiting_verification",
      order_by: [asc: r.inserted_at],
      limit: 5
    )
    |> Repo.all()
  end

  def list_runs(bot_user_id, opts \\ []) do
    query = from(r in Run, where: r.queued_by_id == ^bot_user_id, order_by: [desc: r.inserted_at])

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [r], r.status not in ^@terminal_statuses)
        "all" -> query
        status -> where(query, [r], r.status == ^status)
      end

    Repo.all(query)
  end

  def list_events(run_id) do
    from(e in Event,
      where: e.factory_run_id == ^run_id,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  # -- Claim -----------------------------------------------------------------

  def claim_run(run_id, %{commit_sha: sha}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    token = generate_claim_token()

    txn_result =
      Repo.transaction(fn ->
        result =
          from(r in Run, where: r.id == ^run_id and r.status == "queued")
          |> Repo.update_all(
            set: [
              status: "implementing",
              spec_commit_sha: sha,
              claim_token: token,
              claimed_at: now,
              last_heartbeat_at: now,
              updated_at: now
            ]
          )

        case result do
          {1, _} ->
            run = Repo.get!(Run, run_id)
            append_event(run, "queued", "implementing", "Run claimed")
            run

          {0, _} ->
            Repo.rollback(:already_claimed)
        end
      end)

    case txn_result do
      {:ok, run} ->
        broadcast_update(run)
        {:ok, run}

      {:error, :already_claimed} ->
        {:error, :already_claimed}
    end
  end

  # -- Heartbeat -------------------------------------------------------------

  def heartbeat(run_id, claim_token, message \\ nil) do
    with {:ok, run} <- get_and_validate_token(run_id, claim_token),
         :ok <- validate_active(run) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, run} =
        run
        |> Ecto.Changeset.change(last_heartbeat_at: now)
        |> Repo.update()

      if message do
        append_progress_event(run, message)
        broadcast_update(run)
      end

      {:ok, run}
    end
  end

  # -- Submit Result ---------------------------------------------------------

  def submit_result(run_id, %{claim_token: token, success: success} = params) do
    case get_and_validate_token(run_id, token) do
      {:ok, %Run{status: "implementing"} = run} ->
        if success, do: submit_success(run, params), else: submit_failure(run, params)

      {:ok, %Run{}} ->
        {:error, :invalid_status}

      error ->
        error
    end
  end

  defp submit_success(run, params) do
    run
    |> Ecto.Changeset.change(
      status: "awaiting_verification",
      branch_name: params.branch_name,
      tier1_result: params.summary
    )
    |> Repo.update()
    |> case do
      {:ok, run} ->
        append_event(
          run,
          "implementing",
          "awaiting_verification",
          "Implementation complete — awaiting Tier 2 verification"
        )

        broadcast_update(run)
        {:ok, run}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp submit_failure(run, params) do
    if run.attempt < run.max_attempts do
      run
      |> Ecto.Changeset.change(
        attempt: run.attempt + 1,
        tier1_result: params[:summary]
      )
      |> Repo.update()
      |> case do
        {:ok, run} ->
          append_event(
            run,
            nil,
            nil,
            "Attempt #{run.attempt - 1} failed, retrying (#{run.attempt}/#{run.max_attempts})",
            params[:summary]
          )

          broadcast_update(run)
          {:ok, run}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      run
      |> Ecto.Changeset.change(
        status: "needs_review",
        tier1_result: params[:summary]
      )
      |> Repo.update()
      |> case do
        {:ok, run} ->
          append_event(
            run,
            "implementing",
            "needs_review",
            "All #{run.max_attempts} attempts exhausted — needs human review"
          )

          broadcast_update(run)
          {:ok, run}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # -- Cancel ----------------------------------------------------------------

  def cancel_run(run_id, %{claim_token: token}) do
    with {:ok, run} <- get_and_validate_token(run_id, token) do
      do_cancel(run)
    end
  end

  def cancel_run(run_id, %{bot_user_id: bot_id}) do
    run = Repo.get!(Run, run_id)

    if run.queued_by_id == bot_id do
      do_cancel(run)
    else
      {:error, :unauthorized}
    end
  end

  defp do_cancel(run) do
    if run.status in @terminal_statuses do
      {:error, :already_terminal}
    else
      old_status = run.status

      run
      |> Ecto.Changeset.change(status: "cancelled")
      |> Repo.update()
      |> case do
        {:ok, run} ->
          append_event(run, old_status, "cancelled", "Run cancelled")
          broadcast_update(run)
          {:ok, run}
      end
    end
  end

  # -- Verification ----------------------------------------------------------

  def claim_verification(run_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    token = generate_claim_token()

    txn_result =
      Repo.transaction(fn ->
        result =
          from(r in Run, where: r.id == ^run_id and r.status == "awaiting_verification")
          |> Repo.update_all(
            set: [
              status: "verifying_tier2",
              claim_token: token,
              claimed_at: now,
              last_heartbeat_at: now,
              updated_at: now
            ]
          )

        case result do
          {1, _} ->
            run = Repo.get!(Run, run_id)
            append_event(run, "awaiting_verification", "verifying_tier2", "Verification started")
            run

          {0, _} ->
            Repo.rollback(:already_claimed)
        end
      end)

    case txn_result do
      {:ok, run} ->
        broadcast_update(run)
        {:ok, run}

      {:error, :already_claimed} ->
        {:error, :already_claimed}
    end
  end

  def submit_verification(run_id, %{claim_token: token, passed: passed} = params) do
    case get_and_validate_token(run_id, token) do
      {:ok, %Run{status: "verifying_tier2"} = run} ->
        do_submit_verification(run, passed, params)

      {:ok, %Run{}} ->
        {:error, :invalid_status}

      error ->
        error
    end
  end

  defp do_submit_verification(run, passed, params) do
    tier2_result = %{
      scenarios_run: params.scenarios_run,
      scenarios_passed: params.scenarios_passed,
      details: params[:details]
    }

    new_status = if passed, do: "completed", else: "needs_review"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    completed_at = if passed, do: now, else: run.completed_at

    message = verification_message(passed, params)

    run
    |> Ecto.Changeset.change(
      status: new_status,
      tier2_result: tier2_result,
      completed_at: completed_at
    )
    |> Repo.update()
    |> case do
      {:ok, run} ->
        append_event(run, "verifying_tier2", new_status, message, tier2_result)
        broadcast_update(run)
        {:ok, run}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp verification_message(true, params),
    do: "Tier 2 passed (#{params.scenarios_passed}/#{params.scenarios_run}) — ready for review"

  defp verification_message(false, params),
    do: "Tier 2 failed (#{params.scenarios_passed}/#{params.scenarios_run}) — needs review"

  # -- Lifecycle -------------------------------------------------------------

  @doc """
  Finds runs where `last_heartbeat_at + heartbeat_timeout_minutes < now` and
  releases them:
  - `implementing` -> `queued` (clears claim fields, preserves attempt)
  - `verifying_tier2` -> `awaiting_verification` (clears claim fields)

  Called by `LifecycleWorker` every 2 minutes via Oban cron.
  """
  def release_stale_claims do
    now = DateTime.utc_now()
    truncated_now = DateTime.truncate(now, :microsecond)

    # Find stale implementing runs, then release them individually for event/broadcast
    stale_implementing =
      from(r in Run,
        where: r.status == "implementing",
        where:
          fragment(
            "? + make_interval(mins => ?) < ?",
            r.last_heartbeat_at,
            r.heartbeat_timeout_minutes,
            ^now
          )
      )
      |> Repo.all()

    implementing_count =
      Enum.count(stale_implementing, fn run ->
        {1, _} =
          from(r in Run, where: r.id == ^run.id and r.status == "implementing")
          |> Repo.update_all(
            set: [
              status: "queued",
              claim_token: nil,
              claimed_at: nil,
              last_heartbeat_at: nil,
              branch_name: nil,
              updated_at: truncated_now
            ]
          )

        released = Repo.get!(Run, run.id)
        append_event(released, "implementing", "queued", "Claim released — heartbeat timeout")
        broadcast_update(released)
        true
      end)

    # Find stale verifying_tier2 runs, then release them individually
    stale_verifying =
      from(r in Run,
        where: r.status == "verifying_tier2",
        where:
          fragment(
            "? + make_interval(mins => ?) < ?",
            r.last_heartbeat_at,
            r.heartbeat_timeout_minutes,
            ^now
          )
      )
      |> Repo.all()

    verifying_count =
      Enum.count(stale_verifying, fn run ->
        {1, _} =
          from(r in Run, where: r.id == ^run.id and r.status == "verifying_tier2")
          |> Repo.update_all(
            set: [
              status: "awaiting_verification",
              claim_token: nil,
              claimed_at: nil,
              last_heartbeat_at: nil,
              updated_at: truncated_now
            ]
          )

        released = Repo.get!(Run, run.id)

        append_event(
          released,
          "verifying_tier2",
          "awaiting_verification",
          "Verification claim released — heartbeat timeout"
        )

        broadcast_update(released)
        true
      end)

    {implementing_count + verifying_count, nil}
  end

  # -- Internal helpers -------------------------------------------------------

  defp validate_active(%Run{status: s}) when s in ~w(implementing verifying_tier2), do: :ok
  defp validate_active(_), do: {:error, :not_active}

  defp get_and_validate_token(run_id, token) do
    case Repo.get(Run, run_id) do
      %Run{claim_token: ^token} = run -> {:ok, run}
      %Run{} -> {:error, :invalid_token}
      nil -> {:error, :not_found}
    end
  end

  defp generate_claim_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end

  defp append_event(run, from_status, to_status, message, metadata \\ nil) do
    %Event{}
    |> Event.changeset(%{
      factory_run_id: run.id,
      event_type: "status_change",
      from_status: from_status,
      to_status: to_status,
      message: message,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp append_progress_event(run, message) do
    %Event{}
    |> Event.changeset(%{
      factory_run_id: run.id,
      event_type: "progress",
      message: message
    })
    |> Repo.insert!()
  end

  defp broadcast_update(run) do
    :ok =
      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        "factory:events",
        {:factory_run_updated, run}
      )
  end
end
