defmodule SlackexWeb.MCP.FactoryTools do
  @moduledoc """
  MCP tool definitions and handlers for the dark factory pipeline.
  Delegates all business logic to `Slackex.Factory` context.
  """

  alias Slackex.Factory

  def tools do
    [
      %{
        name: "queue_factory_run",
        description: "Queue a feature spec for dark factory implementation",
        inputSchema: %{
          type: "object",
          required: ["spec_path", "channel_id"],
          properties: %{
            "spec_path" => %{
              type: "string",
              description: "Path to spec directory (e.g. docs/feature/my-feature/)"
            },
            "channel_id" => %{
              type: "string",
              description:
                "Channel ID. Discover human names + IDs via the `list_channels` tool or `tenun:///channels` resource. Prefer using the name in your reasoning."
            }
          }
        }
      },
      %{
        name: "list_factory_work",
        description: "List pending factory runs available for implementation (max 5, FIFO)",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "claim_factory_work",
        description:
          "Claim a queued run for implementation. Returns claim token required for all subsequent updates.",
        inputSchema: %{
          type: "object",
          required: ["run_id", "commit_sha"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"},
            "commit_sha" => %{type: "string", description: "Git HEAD commit SHA"}
          }
        }
      },
      %{
        name: "factory_heartbeat",
        description:
          "Heartbeat to keep a factory run claim alive. Optionally posts a progress message to the run's channel thread.",
        inputSchema: %{
          type: "object",
          required: ["run_id", "claim_token"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"},
            "claim_token" => %{
              type: "string",
              description: "Claim token from claim response"
            },
            "message" => %{type: "string", description: "Optional progress message"}
          }
        }
      },
      %{
        name: "submit_factory_result",
        description:
          "Submit implementation result. On success, moves to verification queue. On failure, retries or escalates to needs_review.",
        inputSchema: %{
          type: "object",
          required: ["run_id", "claim_token", "success"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"},
            "claim_token" => %{type: "string", description: "Claim token"},
            "success" => %{
              type: "boolean",
              description: "Whether implementation + Tier 1 tests passed"
            },
            "branch_name" => %{
              type: "string",
              description: "Git branch name (required if success)"
            },
            "summary" => %{
              type: "object",
              description: "Result summary (test counts, errors, etc.)"
            }
          }
        }
      },
      %{
        name: "list_verification_work",
        description:
          "List factory runs awaiting Tier 2 verification (max 5, FIFO). Returns spec and branch only — no implementation context.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "claim_verification_work",
        description:
          "Claim a run for Tier 2 verification. Returns claim token, spec path, and branch name.",
        inputSchema: %{
          type: "object",
          required: ["run_id"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"}
          }
        }
      },
      %{
        name: "submit_verification",
        description:
          "Submit Tier 2 verification results. Pass moves to completed. Fail moves to needs_review (never retries).",
        inputSchema: %{
          type: "object",
          required: ["run_id", "claim_token", "passed", "scenarios_run", "scenarios_passed"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"},
            "claim_token" => %{type: "string", description: "Claim token"},
            "passed" => %{type: "boolean", description: "Whether all scenarios passed"},
            "scenarios_run" => %{type: "integer", description: "Total scenarios executed"},
            "scenarios_passed" => %{type: "integer", description: "Scenarios that passed"},
            "details" => %{type: "object", description: "Per-scenario results"}
          }
        }
      },
      %{
        name: "list_factory_runs",
        description:
          "List all factory runs with optional status filter. Defaults to non-terminal runs.",
        inputSchema: %{
          type: "object",
          properties: %{
            "status" => %{
              type: "string",
              description: "Filter by status (omit for non-terminal, 'all' for everything)"
            }
          }
        }
      },
      %{
        name: "cancel_factory_run",
        description:
          "Cancel a factory run. Requires claim_token if in-flight, or ownership if queued.",
        inputSchema: %{
          type: "object",
          required: ["run_id"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"},
            "claim_token" => %{
              type: "string",
              description: "Claim token (optional if you own the run)"
            }
          }
        }
      }
    ]
  end

  # -- Tool handlers ---------------------------------------------------------

  def call_tool("queue_factory_run", %{"spec_path" => path, "channel_id" => cid}, session) do
    with {:ok, channel_id} <- parse_id(cid) do
      case Factory.queue_run(%{
             spec_path: path,
             queued_by_id: session.bot_user.id,
             channel_id: channel_id
           }) do
        {:ok, run} ->
          # Factory coordination polish (slice 2c): resolve human name for the
          # chosen status channel_id here in the MCP response (thin lookup).
          # This makes the name visible to the calling agent / in plans/logs
          # without altering the core run record or channel_id contract.
          channel_name = get_channel_name(channel_id)

          {:ok,
           json_content(%{
             run_id: to_string(run.id),
             status: run.status,
             channel_name: channel_name
           })}

        {:error, changeset} ->
          {:error, format_errors(changeset)}
      end
    end
  end

  def call_tool("list_factory_work", _args, session) do
    runs = Factory.list_pending(session.bot_user.id)
    data = Enum.map(runs, &serialize_run_summary/1)
    {:ok, json_content(data)}
  end

  def call_tool("claim_factory_work", %{"run_id" => rid, "commit_sha" => sha}, _session) do
    with {:ok, run_id} <- parse_id(rid) do
      case Factory.claim_run(run_id, %{commit_sha: sha}) do
        {:ok, run} ->
          # Factory polish: surface human-readable channel name alongside the
          # numeric channel_id in the claim response (the point at which the
          # agent learns/operates the status thread location).
          channel_name = get_channel_name(run.channel_id)

          {:ok,
           json_content(%{
             claim_token: run.claim_token,
             spec_path: run.spec_path,
             spec_commit_sha: run.spec_commit_sha,
             channel_id: to_string(run.channel_id),
             channel_name: channel_name,
             thread_message_id: run.thread_message_id && to_string(run.thread_message_id),
             attempt: run.attempt,
             max_attempts: run.max_attempts
           })}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  def call_tool(
        "factory_heartbeat",
        %{"run_id" => rid, "claim_token" => token} = args,
        _session
      ) do
    with {:ok, run_id} <- parse_id(rid) do
      case Factory.heartbeat(run_id, token, args["message"]) do
        {:ok, _} -> {:ok, json_content(%{ok: true})}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  def call_tool(
        "submit_factory_result",
        %{"run_id" => rid, "claim_token" => token} = args,
        _session
      ) do
    with {:ok, run_id} <- parse_id(rid) do
      params = %{
        claim_token: token,
        success: args["success"],
        branch_name: args["branch_name"],
        summary: args["summary"] || %{}
      }

      case Factory.submit_result(run_id, params) do
        {:ok, run} -> {:ok, json_content(submit_result_payload(run))}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  def call_tool("list_verification_work", _args, session) do
    runs = Factory.list_pending_verification(session.bot_user.id)

    data =
      Enum.map(runs, fn r ->
        %{
          run_id: to_string(r.id),
          spec_path: r.spec_path,
          spec_commit_sha: r.spec_commit_sha,
          branch_name: r.branch_name
        }
      end)

    {:ok, json_content(data)}
  end

  def call_tool("claim_verification_work", %{"run_id" => rid}, _session) do
    with {:ok, run_id} <- parse_id(rid) do
      case Factory.claim_verification(run_id) do
        {:ok, run} ->
          {:ok,
           json_content(%{
             claim_token: run.claim_token,
             spec_path: run.spec_path,
             spec_commit_sha: run.spec_commit_sha,
             branch_name: run.branch_name
           })}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  def call_tool(
        "submit_verification",
        %{"run_id" => rid, "claim_token" => token} = args,
        _session
      ) do
    with {:ok, run_id} <- parse_id(rid) do
      params = %{
        claim_token: token,
        passed: args["passed"],
        scenarios_run: args["scenarios_run"],
        scenarios_passed: args["scenarios_passed"],
        details: args["details"] || %{}
      }

      case Factory.submit_verification(run_id, params) do
        {:ok, run} -> {:ok, json_content(%{status: run.status})}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  def call_tool("list_factory_runs", args, session) do
    opts =
      case args["status"] do
        nil -> []
        status -> [status: status]
      end

    runs = Factory.list_runs(session.bot_user.id, opts)
    data = Enum.map(runs, &serialize_run_summary/1)
    {:ok, json_content(data)}
  end

  def call_tool("cancel_factory_run", %{"run_id" => rid} = args, session) do
    with {:ok, run_id} <- parse_id(rid) do
      cancel_params =
        if args["claim_token"],
          do: %{claim_token: args["claim_token"]},
          else: %{bot_user_id: session.bot_user.id}

      case Factory.cancel_run(run_id, cancel_params) do
        {:ok, run} -> {:ok, json_content(%{status: run.status})}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  def call_tool(name, _args, _session), do: {:error, "Unknown factory tool: #{name}"}

  # -- Helpers ---------------------------------------------------------------

  defp submit_result_payload(run) do
    result = %{status: run.status, attempt: run.attempt, max_attempts: run.max_attempts}

    if run.status == "implementing",
      do: Map.put(result, :retry, true),
      else: result
  end

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid ID: #{str}"}
    end
  end

  defp parse_id(_), do: {:error, "Invalid ID"}

  # Thin name resolver for factory coordination polish (visible channel name
  # when queue/claim use a status channel_id). Safe (no crash on bad ID).
  # Uses same Chat lookup as server get_channel / send enrichment.
  defp get_channel_name(channel_id) when is_integer(channel_id) do
    case safe_get_channel(channel_id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  defp get_channel_name(_), do: nil

  defp safe_get_channel(id) do
    try do
      Slackex.Chat.get_channel!(id)
    rescue
      _ -> nil
    end
  end

  defp json_content(data) do
    [%{type: "text", text: Jason.encode!(data)}]
  end

  defp serialize_run_summary(run) do
    %{
      run_id: to_string(run.id),
      spec_path: run.spec_path,
      status: run.status,
      attempt: run.attempt,
      branch_name: run.branch_name,
      inserted_at: DateTime.to_iso8601(run.inserted_at)
    }
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> inspect()
  end

  defp format_errors(other), do: inspect(other)
end
