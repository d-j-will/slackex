defmodule Slackex.Factory do
  @moduledoc """
  Context for the dark factory pipeline. Manages factory runs through their
  lifecycle: queued -> implementing -> awaiting_verification -> verifying_tier2
  -> completed.

  All state transitions are enforced here. MCP tools delegate to this module.
  """

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
      {:ok, %{run: run}} -> {:ok, run}
      {:error, :run, changeset, _} -> {:error, changeset}
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
        broadcast_update(run)
        {:ok, run}

      {0, _} ->
        {:error, :already_claimed}
    end
  end

  # -- Heartbeat -------------------------------------------------------------

  def heartbeat(run_id, claim_token, message \\ nil) do
    with {:ok, run} <- get_and_validate_token(run_id, claim_token) do
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
    with {:ok, run} <- get_and_validate_token(run_id, token) do
      if success do
        submit_success(run, params)
      else
        submit_failure(run, params)
      end
    end
  end

  defp submit_success(run, params) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    run
    |> Ecto.Changeset.change(
      status: "awaiting_verification",
      branch_name: params.branch_name,
      tier1_result: params.summary,
      completed_at: now
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

  # -- Internal helpers -------------------------------------------------------

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
