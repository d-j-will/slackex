defmodule Slackex.Andon do
  @moduledoc """
  Andon relay: slackex's implementation of the andon service's relay contract
  (relay #1, ADR-0002). slackex owns its platform's half of C1 — parsing the
  `pull:` grammar and the in-thread affordances, rendering presentation
  commands, thread mechanics, the edited-in-place status mirror — and speaks
  domain events to the service with platform details (person, channel, thread,
  message) as opaque tokens the service never interprets.

  This facade is the boundary's public surface:

    * `process_message/2` — a channel message became a domain event (or not);
      the `Listener` calls it for every `message.new` on a relay-enabled
      channel while `:andon_relay` is on.
    * `apply_command/1` — an outbound push from the service (`notify_backup`,
      `update_mirror`); the inbound controller calls it.
    * `enable_channel/1`, `enabled?/1`, `bot_user/0` — channel + bot lifecycle.

  ## Design decisions (contract points v1 fixes)

    * **event_id is derived from the Slack message id** (`slackex-<message_id>`),
      not a fresh value. The listener runs on every node of a clustered deploy
      and each node sees the same PubSub broadcast; a stable id lets the service
      collapse the duplicates. Each Slack message yields exactly one domain
      event, so the message id is a stable unique key.
    * **Response commands execute only on `201 Created`.** A `200` is an
      idempotent replay whose commands (`notify_dri`, `request_subject`) were
      already rendered on the original `201`; skipping them is the relay's
      dedup. (Caveat: a crash between receiving `201` and rendering means a
      later `200` won't re-render — acceptable for the skeleton.)
    * **Affordances are recognised only in a thread** (a reply). A bare `ack`
      or issue key at channel top-level is ordinary traffic, not an act on a
      pull. The `pull:` grammar is recognised at top-level *and* in a thread (a
      recurrence is a new pull citing the closure).
    * **`closed_without_puller` has no affordance in v1** (deferred). `resolved`
      always sends a plain `witness_close`; a non-witness close is refused by
      the service (403) and surfaced as an in-thread note.
  """

  use Boundary,
    deps: [Slackex.Accounts, Slackex.Chat, Slackex.Messaging],
    exports: [Channel, Grammar, Affordances, Listener, ServiceClient]

  import Ecto.Query

  alias Slackex.Accounts
  alias Slackex.Andon.{Affordances, Channel, Grammar, Mirror, ServiceClient, ThreadReplyWorker}
  alias Slackex.Chat
  alias Slackex.Chat.Channels
  alias Slackex.Chat.Messages
  alias Slackex.Messaging
  alias Slackex.Repo

  require Logger

  @bot_username "andon"
  @relay "slackex"
  @control_topic "andon:control"

  # ---------------------------------------------------------------------------
  # Channel + bot lifecycle
  # ---------------------------------------------------------------------------

  @doc "Returns the control PubSub topic listeners subscribe to for enablement."
  def control_topic, do: @control_topic

  @doc "Lists the channel ids currently relay-enabled."
  @spec enabled_channel_ids() :: [integer()]
  def enabled_channel_ids do
    Repo.all(from c in Channel, select: c.channel_id)
  end

  @doc "Returns the `andon_channels` row for a channel, or nil."
  @spec get_channel(integer()) :: Channel.t() | nil
  def get_channel(channel_id) do
    Repo.get_by(Channel, channel_id: channel_id)
  end

  @doc "True when the channel is relay-enabled."
  @spec enabled?(integer()) :: boolean()
  def enabled?(channel_id), do: not is_nil(get_channel(channel_id))

  @doc """
  Enables the relay on a channel: inserts the `andon_channels` row, ensures the
  bot user exists, and announces the channel on the control topic so every
  running `Listener` (this node and, in a cluster, others) subscribes to it.
  """
  @spec enable_channel(integer()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def enable_channel(channel_id) do
    # The bot must be a channel member to post/edit (the same constraint the
    # webhook bot has); join_channel is idempotent and rejects private channels.
    bot = bot_user()
    _ = Channels.join_channel(bot.id, channel_id)

    %Channel{}
    |> Channel.enable_changeset(%{channel_id: channel_id})
    |> Repo.insert()
    |> case do
      {:ok, row} ->
        _ =
          Phoenix.PubSub.broadcast(
            Slackex.PubSub,
            @control_topic,
            {:andon_channel_enabled, channel_id}
          )

        {:ok, row}

      error ->
        error
    end
  end

  @doc "Gets or creates the single andon bot user (posts and edits run as it)."
  @spec bot_user() :: struct()
  def bot_user do
    case Accounts.get_bot_by_username(@bot_username) do
      nil ->
        case Accounts.create_bot_user(%{username: @bot_username, display_name: "Andon"}) do
          {:ok, user} -> user
          # Lost a race with a concurrent create — fetch the winner.
          {:error, _} -> Accounts.get_bot_by_username(@bot_username)
        end

      user ->
        user
    end
  end

  # ---------------------------------------------------------------------------
  # Inbound: a channel message → a domain event (relay → service)
  # ---------------------------------------------------------------------------

  @doc """
  Turns one `message.new` payload into a domain event and posts it, then
  renders any response commands. `ctx` carries `:channel_id` and `:bot_id`.
  Returns `:ok` always — nothing here may crash the listener.
  """
  @spec process_message(map(), %{channel_id: integer(), bot_id: integer()}) :: :ok
  def process_message(payload, %{bot_id: bot_id} = ctx) do
    message_id = fetch(payload, :id)
    sender_id = fetch(payload, :sender_id)
    parent_id = fetch(payload, :parent_message_id)
    content = fetch(payload, :content) || ""

    cond do
      # Never act on our own bot posts (corrections, asks, mirror) — no loops.
      sender_id == bot_id -> :ok
      is_nil(message_id) or is_nil(sender_id) -> :ok
      true -> classify_and_dispatch(content, message_id, sender_id, parent_id, ctx)
    end
  rescue
    error ->
      Logger.warning("andon relay: process_message crashed: #{inspect(error)}")
      :ok
  end

  # The message.new payload uses atom keys from ChannelServer but may arrive
  # with string keys (e.g. a re-decoded envelope); read either.
  defp fetch(payload, key), do: payload[key] || payload[to_string(key)]

  defp classify_and_dispatch(content, message_id, sender_id, parent_id, ctx) do
    thread_id = parent_id || message_id
    origin = origin(ctx.channel_id, thread_id, message_id)
    reply? = not is_nil(parent_id)

    case Grammar.parse(content) do
      {:pull, class, sentence} ->
        pull_created(class, sentence, message_id, sender_id, origin)
        |> post_and_render(ctx, thread_id)

      :correction ->
        post_in_thread(ctx, thread_id, correction_text())

      :not_a_pull when reply? ->
        dispatch_affordance(
          Affordances.parse(content),
          message_id,
          sender_id,
          origin,
          ctx,
          thread_id
        )

      :not_a_pull ->
        :ok
    end
  end

  defp dispatch_affordance(:none, _mid, _sid, _origin, _ctx, _thread), do: :ok

  defp dispatch_affordance(intent, message_id, sender_id, origin, ctx, thread_id) do
    intent
    |> affordance_event(message_id, sender_id, origin)
    |> post_and_render(ctx, thread_id)
  end

  # -- Event builders ---------------------------------------------------------

  defp pull_created(class, sentence, message_id, sender_id, origin) do
    base("pull_created", message_id, origin)
    |> Map.merge(%{
      "puller" => token(sender_id),
      "class" => class,
      "sentence" => sentence
    })
  end

  defp affordance_event(:ack, mid, sid, origin),
    do: base("ack", mid, origin) |> Map.put("actor", token(sid))

  defp affordance_event(:witness_close, mid, sid, origin),
    do: base("witness_close", mid, origin) |> Map.put("actor", token(sid))

  defp affordance_event(:withdraw, mid, sid, origin),
    do: base("pull_withdrawn", mid, origin) |> Map.put("puller", token(sid))

  defp affordance_event({:closure_note, note}, mid, sid, origin),
    do: base("closure_note", mid, origin) |> Map.merge(%{"actor" => token(sid), "note" => note})

  defp affordance_event({:subject, key}, mid, sid, origin),
    do:
      base("subject_provided", mid, origin)
      |> Map.merge(%{"provider" => token(sid), "key" => key})

  defp base(event, message_id, origin) do
    %{
      "event" => event,
      "event_id" => "#{@relay}-#{message_id}",
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "origin" => origin
    }
  end

  defp origin(channel_id, thread_id, message_id) do
    %{
      "relay" => @relay,
      "channel" => to_string(channel_id),
      "thread" => to_string(thread_id),
      "message" => to_string(message_id)
    }
  end

  defp token(user_id), do: %{"relay" => @relay, "token" => to_string(user_id)}

  # -- Post + render the response --------------------------------------------

  defp post_and_render(event, ctx, thread_id) do
    case ServiceClient.post_event(event) do
      {:ok, %{status: 201, body: body}} ->
        run_commands(Map.get(body, "commands", []), ctx)
        maybe_confirm_pull(event, body, ctx, thread_id)
        maybe_ack_lifecycle(event, ctx, thread_id)

      {:ok, %{status: 200}} ->
        # Idempotent replay — commands already rendered on the original 201.
        :ok

      {:ok, %{status: status, body: body}} when status in 400..499 ->
        post_in_thread(ctx, thread_id, error_note(body))

      {:ok, %{status: status}} ->
        Logger.warning("andon relay: service returned #{status} for #{event["event"]}")
        :ok

      {:error, _reason} ->
        # Already logged by the client; the listener must not crash.
        :ok
    end
  end

  # The puller's own confirmation (ENG-13 gap 3): on a fresh bind, tell the
  # puller their pull landed and how they release it, so a pull never *feels*
  # unanswered while humans are slow. Rendered from the 201 the relay already
  # has — a bound `pull_created` (explicit key) or a `subject_provided` that
  # binds a previously-unbound pull. An unbound pull gets `request_subject`
  # instead; its confirmation follows when the subject is provided. Only the
  # puller's affordance (`resolved`) is taught here — the DRI's (`ack`/`note:`)
  # rides the separate notify_dri ping (response-protocol role split). Only on
  # the 201 (a 200 is an idempotent replay already rendered).
  defp maybe_confirm_pull(%{"event" => event}, body, ctx, thread_id)
       when event in ["pull_created", "subject_provided"] do
    case get_in(body, ["data", "binding"]) do
      %{"bound" => true} = binding -> post_in_thread(ctx, thread_id, puller_confirmation(binding))
      _ -> :ok
    end
  end

  defp maybe_confirm_pull(_event, _body, _ctx, _thread_id), do: :ok

  defp puller_confirmation(binding) do
    subject = get_in(binding, ["subject", "external_id"])
    bound = if is_binary(subject), do: " · bound to #{subject}", else: ""

    # "held at its gate" holds for a work-item pull (the skeleton's only kind —
    # binding applies the hold, ENG-6). A system-object pull (gate/line/rollout)
    # does NOT hold ("nothing holds — the pull is notify, clocks, and log",
    # response-protocol); revisit this line when those land.
    "Logged#{bound} · held at its gate.\n" <>
      "On the clock — reply `resolved` when what you flagged is contained."
  end

  # A lifecycle affordance (`ack`/`resolved`/`note:`) records in the log but the
  # service returns no command, so without this the act is silent in the thread
  # — you press the button gap 2 taught and nothing shows. Render a light
  # acknowledgment on the 201 so each transition is visible ("reads like the
  # pull"). The `resolved`/`ack`/`closure_note` 201s carry no subject, so the
  # release line names none — the thread already has it.
  defp maybe_ack_lifecycle(%{"event" => "ack"} = event, ctx, thread_id) do
    post_in_thread(ctx, thread_id, "#{mention(event["actor"])} acknowledged · engaging now.")
  end

  defp maybe_ack_lifecycle(%{"event" => "witness_close"}, ctx, thread_id) do
    post_in_thread(ctx, thread_id, "Released · the hold is cleared.")
  end

  defp maybe_ack_lifecycle(%{"event" => "closure_note"}, ctx, thread_id) do
    post_in_thread(ctx, thread_id, "Closure note logged.")
  end

  defp maybe_ack_lifecycle(_event, _ctx, _thread_id), do: :ok

  # ---------------------------------------------------------------------------
  # Outbound push: service → relay (the inbound HTTP endpoint calls this)
  # ---------------------------------------------------------------------------

  @doc """
  Applies an outbound presentation command pushed by the service. Returns `:ok`
  even when the target is unknown here — a push for a channel this relay does
  not serve is dropped, not an error.
  """
  @spec apply_command(map()) :: :ok
  def apply_command(
        %{"command" => "notify_backup", "backup" => backup, "thread" => thread} = command
      ) do
    case resolve_channel(command) do
      {:ok, channel_id} ->
        ctx = %{channel_id: channel_id, bot_id: bot_user().id}

        post_in_thread(
          ctx,
          thread,
          "Backup #{mention(backup)} — the acknowledge window lapsed; you now carry this pull.\n" <>
            dri_affordances()
        )

      :error ->
        # A safety-critical escalation we cannot place. Never silent — losing a
        # backup notification without a trace is exactly the failure a response
        # system must surface.
        Logger.warning(
          "andon relay: dropped notify_backup, unresolvable channel " <>
            "(channel=#{inspect(command["channel"])} thread=#{inspect(thread)})"
        )

        :ok
    end
  end

  def apply_command(%{"command" => "update_mirror", "channel" => channel} = command) do
    watermark = command["watermark"]
    mirror = command["mirror"] || %{}

    with {int, ""} <- Integer.parse(to_string(channel)),
         %Channel{} = row <- get_channel(int) do
      apply_mirror(row, watermark, mirror)
    else
      _ -> :ok
    end
  end

  # The service pushes the DRI notification here (off its own request path) so
  # it rides the one channel the relay reliably renders. Reuse the response-path
  # renderer — the ping is identical whether it arrives inline on a 201 or as an
  # outbound push.
  def apply_command(%{"command" => "notify_dri", "thread" => thread} = command) do
    case resolve_channel(command) do
      {:ok, channel_id} ->
        run_command(command, %{channel_id: channel_id, bot_id: bot_user().id})

      :error ->
        Logger.warning(
          "andon relay: dropped notify_dri, unresolvable channel " <>
            "(channel=#{inspect(command["channel"])} thread=#{inspect(thread)})"
        )

        :ok
    end
  end

  def apply_command(_other), do: :ok

  defp apply_mirror(%Channel{last_watermark: applied}, watermark, _mirror)
       when is_integer(watermark) and watermark <= applied do
    # Stale or repeated — the relay applies only strictly-greater watermarks.
    :ok
  end

  defp apply_mirror(%Channel{channel_id: channel_id} = row, watermark, mirror) do
    text = Mirror.render(mirror)
    bot = bot_user()

    _ =
      case row.status_message_id do
        nil ->
          # Create synchronously (Chat, not the async Messaging hot path) so the
          # row exists for the edit-in-place that every later update performs.
          case Messages.send_message(channel_id, bot.id, text) do
            {:ok, message} ->
              update_mirror_row(row, %{status_message_id: message.id, last_watermark: watermark})

            {:error, reason} ->
              Logger.warning("andon relay: mirror create failed: #{inspect(reason)}")
          end

        status_message_id ->
          case Messaging.edit_message(status_message_id, bot.id, text) do
            {:ok, _} ->
              update_mirror_row(row, %{last_watermark: watermark})

            {:error, reason} ->
              Logger.warning("andon relay: mirror edit failed: #{inspect(reason)}")
          end
      end

    :ok
  end

  defp update_mirror_row(row, attrs) do
    case row |> Channel.mirror_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        {:ok, updated}

      {:error, changeset} ->
        # The mirror message posted/edited but the row didn't record it; log so
        # a stuck watermark or a lost status_message_id isn't silent.
        Logger.warning("andon relay: mirror row update failed: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  # ---------------------------------------------------------------------------
  # Presentation helpers (bot posts into a thread)
  # ---------------------------------------------------------------------------

  # Response commands ride a pull_created/subject_provided 201.
  defp run_commands(commands, ctx) when is_list(commands) do
    Enum.each(commands, &run_command(&1, ctx))
  end

  defp run_commands(_commands, _ctx), do: :ok

  defp run_command(%{"command" => "request_subject", "thread" => thread}, ctx) do
    post_in_thread(
      ctx,
      thread,
      "Which work item is this pull about? Reply in this thread with its key, e.g. ENG-123."
    )
  end

  defp run_command(%{"command" => "notify_dri", "dri" => dri, "thread" => thread}, ctx) do
    post_in_thread(
      ctx,
      thread,
      "#{mention(dri)} — you're the DRI for this pull. It's on the clock.\n" <>
        dri_affordances()
    )
  end

  defp run_command(_unknown, _ctx), do: :ok

  # The DRI's in-thread affordances (ENG-13 gap 2), taught wherever someone
  # becomes the DRI — the initial notify and a backup inheriting the pull. The
  # puller's affordances (`resolved` to release, `withdraw`) are the puller's,
  # taught in the puller confirmation, not here (response-protocol role split).
  # `ack` is bare; `note:` carries the note text after the colon (Affordances).
  defp dri_affordances do
    "Reply `ack` to acknowledge · `note: <text>` once it's addressed."
  end

  # Posts as the bot into the Slack thread rooted at `thread` (a message id) by
  # enqueuing a durable ThreadReplyWorker job. slackex persists channel messages
  # asynchronously (ChannelServer broadcasts message.new, then a Task writes the
  # row), so the parent a relay reply targets can lag its broadcast past any
  # in-listener wait (slackex-xqd: the field lag was >700ms). The worker owns the
  # retry-until-persisted off this path, so the listener never blocks and a reply
  # is never dropped to a slow write. Enqueue only — the listener must not crash.
  defp post_in_thread(%{channel_id: channel_id, bot_id: bot_id}, thread, text) do
    case ThreadReplyWorker.enqueue(channel_id, bot_id, thread, text) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "andon relay: could not enqueue thread reply for #{inspect(thread)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp correction_text do
    "That doesn't look like a pull. Use `pull: <class> <one sentence>` where " <>
      "class is one of: #{Enum.join(Grammar.classes(), ", ")}."
  end

  defp error_note(%{"errors" => errors}) when is_map(errors) do
    errors
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> "The service couldn't accept that."
      message -> message
    end
  end

  defp error_note(_body), do: "The service couldn't accept that."

  # A token is a slackex user id; render it as a @username mention when we can
  # resolve it, else fall back to the raw token (cross-relay/pinned tokens).
  defp mention(%{"token" => token}), do: mention(token)

  defp mention(token) when is_binary(token) do
    with {int, ""} <- Integer.parse(token),
         %{username: username} <- Accounts.get_user(int) do
      "@#{username}"
    else
      _ -> "@#{token}"
    end
  end

  # Every thread-addressed command now carries its channel (service fix,
  # andon-proto-claude 8d6d431), so prefer the explicit token and skip the DB
  # lookup. Fall back to resolving it from the thread message for robustness
  # (a pre-fix payload, or a malformed/absent channel token).
  defp resolve_channel(command) do
    with channel when not is_nil(channel) <- command["channel"],
         {channel_id, ""} <- Integer.parse(to_string(channel)) do
      {:ok, channel_id}
    else
      _ -> channel_of_thread(command["thread"])
    end
  end

  defp channel_of_thread(thread) do
    with {message_id, ""} <- Integer.parse(to_string(thread)),
         {:ok, %{channel_id: channel_id}} when not is_nil(channel_id) <-
           Chat.get_message(message_id) do
      {:ok, channel_id}
    else
      _ -> :error
    end
  end
end
