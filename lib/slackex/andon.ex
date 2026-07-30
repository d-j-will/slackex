defmodule Slackex.Andon do
  @moduledoc """
  Andon relay: slackex's implementation of the andon service's relay contract
  (relay #1, ADR-0002). slackex owns its platform's half of C1 — parsing the
  `pull:` grammar and the in-thread phrases, rendering presentation
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
    * **Phrases are recognised only in a thread** (a reply). A bare `ack`
      or issue key at channel top-level is ordinary traffic, not an act on a
      pull. The `pull:` grammar is recognised at top-level *and* in a thread (a
      recurrence is a new pull citing the closure).
    * **`closed_without_puller` cannot be invoked in v1** (deferred) — no
      phrase, no button. `resolved`
      always sends a plain `witness_close`; a non-witness close is refused by
      the service (403) and surfaced as an in-thread note.
  """

  use Boundary,
    deps: [Slackex.Accounts, Slackex.Chat, Slackex.Messaging],
    exports: [Channel, Grammar, Help, Phrases, Listener, ServiceClient]

  import Ecto.Query

  alias Slackex.Accounts

  alias Slackex.Andon.{
    Channel,
    Grammar,
    Help,
    Mirror,
    NotePrompt,
    Phrases,
    ServiceClient,
    ThreadReplyWorker
  }

  alias Slackex.Chat
  alias Slackex.Chat.Channels
  alias Slackex.Chat.Messages
  alias Slackex.Messaging
  alias Slackex.Repo

  require Logger

  # What each class sounds like in the words people use for it, rather than a
  # definition of the term. A class with no gloss still lists — the classes
  # come from Grammar so the two cannot drift.
  @class_glosses %{
    "defect" => "something is broken",
    "delay" => "it is waiting on someone",
    "burden" => "it is grinding you down",
    "confusion" => "you cannot see the shape of it"
  }

  @bot_username "andon"
  @relay "slackex"
  @control_topic "andon:control"

  # The two acts that answer the question at release. Both name their pull
  # when the thread has been asked one (andon ADR-0017).
  @closure_acts ["closure_note", "closure_note_declined"]

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
  A hold-card button: the viewer acts on a hold without opening its thread.
  `action` is `"release"` (the witness's release) or `"ack"`.

  The event id is derived rather than taken from a message, because a click
  has no message of its own: `slackex-act-<pull_id>-<event>-<epoch>-<token>`.
  It is deterministic, so a double-click is an idempotent replay rather than a
  second attempt — the service pins this exact shape in its own suite
  (`thread_lifecycle_test.exs`, "button-derived event ids"). The epoch is the
  acknowledge round the snapshot was rendered from, so an ack answers the
  round the viewer was actually looking at.

  Authorization is the service's: the card only offers what the snapshot says
  the viewer may do, and the service refuses anything else exactly as it would
  a typed phrase.
  """
  @spec act_on_hold(map(), String.t(), integer(), integer(), integer()) :: :ok
  def act_on_hold(hold, action, channel_id, status_message_id, user_id)
      when action in ["release", "ack"] do
    event = if action == "release", do: "witness_close", else: "ack"
    actor = token(user_id)
    thread = to_string(hold["thread"])

    %{
      "event" => event,
      "event_id" =>
        "#{@relay}-act-#{hold["pull_id"]}-#{event}-#{hold["epoch"] || 0}-#{actor["token"]}",
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "actor" => actor,
      "origin" => origin(channel_id, thread, status_message_id)
    }
    |> post_and_render(%{channel_id: channel_id, bot_id: bot_user().id}, thread_id(thread))
  end

  defp thread_id(thread) do
    case Integer.parse(thread) do
      {id, ""} -> id
      _ -> nil
    end
  end

  @doc "PubSub topic carrying this channel's mirror snapshots."
  @spec mirror_topic(integer()) :: String.t()
  def mirror_topic(channel_id), do: "andon:mirror:channel:#{channel_id}"

  @doc """
  The channel's latest mirror snapshot as `%{status_message_id => mirror}`,
  or an empty map when the relay is off or nothing has been mirrored yet.
  Shaped like the assign the card renders from, so a viewer arriving between
  updates sees the same holds as one who was watching.
  """
  @spec mirror_for_channel(integer()) :: %{optional(integer()) => map()}
  def mirror_for_channel(channel_id) do
    case get_channel(channel_id) do
      %Channel{status_message_id: id, mirror: %{} = mirror} when not is_nil(id) ->
        %{id => mirror}

      _ ->
        %{}
    end
  end

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

    # Asked before parsed: someone asking what they can type has, by
    # definition, not typed it yet, so this cannot wait behind the grammar.
    # It answers in a thread on the asking message, the same way a correction
    # does — the reply lands where the question was.
    if Help.asked?(content) do
      post_in_thread(ctx, thread_id, help_text())
    else
      dispatch_parsed(content, message_id, sender_id, origin, ctx, thread_id, reply?)
    end
  end

  defp dispatch_parsed(content, message_id, sender_id, origin, ctx, thread_id, reply?) do
    case Grammar.parse(content) do
      {:pull, class, sentence} ->
        pull_created(class, sentence, message_id, sender_id, origin)
        |> post_and_render(ctx, thread_id)

      :correction ->
        post_in_thread(ctx, thread_id, correction_text())

      :not_a_pull when reply? ->
        case Phrases.parse(content) do
          # Ordinary thread traffic — unless the bot asked this person a
          # question and is still waiting (ENG-60). The guard that keeps
          # chatter out of the log is suspended for exactly one message.
          :none ->
            maybe_capture_answer(content, message_id, sender_id, origin, ctx, thread_id)

          intent ->
            dispatch_intent(intent, message_id, sender_id, origin, ctx, thread_id)
        end

      :not_a_pull ->
        :ok
    end
  end

  # The answer to the question at release, in plain words. Only the person
  # the question was addressed to can spend the arming, and it is spent on
  # first use whether or not it produced a note — nothing re-arms and nothing
  # re-asks, because the friction budget is one question.
  #
  # A prompted answer still needs its `cause:` marker: the bot asked for both
  # halves in one message and taught the marker in the asking. Without it the
  # note is not logged as half a note — the existing cause prompt asks, and
  # the arming is already gone, so that ask is the last word.
  defp maybe_capture_answer(content, message_id, sender_id, origin, ctx, thread_id) do
    with true <- is_integer(thread_id),
         {:ok, prompt} <- NotePrompt.take(ctx.channel_id, thread_id, to_string(sender_id)) do
      case Phrases.answer(content) do
        {:closure_note, note, cause} ->
          base("closure_note", message_id, origin)
          |> Map.merge(%{
            "actor" => token(sender_id),
            "note" => note,
            "cause_guess" => cause,
            "pull_id" => prompt.pull_id
          })
          |> post_and_render(ctx, thread_id)

        _no_cause_or_empty ->
          post_in_thread(ctx, thread_id, cause_prompt_text())
      end
    else
      _not_being_asked -> :ok
    end
  end

  # A note with no cause-guess is not logged as half a note. The cause is the
  # part that cannot be reconstructed weeks later, so the bot asks for it in
  # the thread while the person still has the answer in their head.
  defp dispatch_intent(
         {:closure_note_needs_cause, _note},
         _mid,
         _sid,
         _origin,
         ctx,
         thread_id
       ),
       do: post_in_thread(ctx, thread_id, cause_prompt_text())

  defp dispatch_intent(intent, message_id, sender_id, origin, ctx, thread_id) do
    intent
    |> intent_event(message_id, sender_id, origin)
    |> with_pull_id(ctx, thread_id)
    |> post_and_render(ctx, thread_id)
  end

  # A closure act names the pull the thread's last question was about (andon
  # ADR-0017). Without it the service resolves by thread state, which is
  # ambiguous once a thread holds two closed pulls — and ENG-52's thread
  # inheritance puts recurrences in exactly that thread. Where no question was
  # ever asked here, the event carries no id and the service falls back
  # exactly as it did before.
  defp with_pull_id(%{"event" => name} = event, ctx, thread_id) when name in @closure_acts do
    with true <- is_integer(thread_id),
         %NotePrompt{pull_id: pull_id} <- NotePrompt.latest(ctx.channel_id, thread_id) do
      Map.put(event, "pull_id", pull_id)
    else
      _never_asked_here -> event
    end
  end

  defp with_pull_id(event, _ctx, _thread_id), do: event

  # -- Event builders ---------------------------------------------------------

  # The bare cord (ENG-45) omits the class field rather than sending null:
  # the seam carries facts, and "no class yet" is the absence of one.
  defp pull_created(nil, sentence, message_id, sender_id, origin) do
    base("pull_created", message_id, origin)
    |> Map.merge(%{"puller" => token(sender_id), "sentence" => sentence})
  end

  defp pull_created(class, sentence, message_id, sender_id, origin) do
    base("pull_created", message_id, origin)
    |> Map.merge(%{
      "puller" => token(sender_id),
      "class" => class,
      "sentence" => sentence
    })
  end

  defp intent_event(:ack, mid, sid, origin),
    do: base("ack", mid, origin) |> Map.put("actor", token(sid))

  defp intent_event(:witness_close, mid, sid, origin),
    do: base("witness_close", mid, origin) |> Map.put("actor", token(sid))

  defp intent_event(:withdraw, mid, sid, origin),
    do: base("pull_withdrawn", mid, origin) |> Map.put("puller", token(sid))

  defp intent_event({:closure_note, note, cause}, mid, sid, origin),
    do:
      base("closure_note", mid, origin)
      |> Map.merge(%{"actor" => token(sid), "note" => note, "cause_guess" => cause})

  # "No note" is an answer and a recorded outcome, not a silence (ENG-60).
  defp intent_event(:closure_note_declined, mid, sid, origin),
    do: base("closure_note_declined", mid, origin) |> Map.put("actor", token(sid))

  defp intent_event({:subject, key}, mid, sid, origin),
    do:
      base("subject_provided", mid, origin)
      |> Map.merge(%{"provider" => token(sid), "key" => key})

  defp intent_event({:class, class}, mid, sid, origin),
    do:
      base("class_provided", mid, origin)
      |> Map.merge(%{"provider" => token(sid), "class" => class})

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
        maybe_ask_class(event, ctx, thread_id)
        maybe_ack_lifecycle(event, body, ctx, thread_id)

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
  # puller's phrase (`resolved`) is taught here — the DRI's (`ack`/`note:`)
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

  # The class question (ENG-45): a bare pull is asked once, right after
  # whatever else the creation rendered (the confirmation, or the subject
  # ask), so the first thing the puller reads is that help is coming and the
  # question reads as optional detail, never a gate. Once and only once —
  # this renders on the 201 alone, so a replay never re-asks, and nothing
  # ever reminds. Silence leaves the pull unclassed, which is a visible
  # state, not a failure. Only the relay knows the pull went classless (it
  # parsed the message), which is why this is not a service command.
  defp maybe_ask_class(%{"event" => "pull_created"} = event, ctx, thread_id)
       when not is_map_key(event, "class") do
    post_in_thread(ctx, thread_id, class_question_text())
  end

  defp maybe_ask_class(_event, _ctx, _thread_id), do: :ok

  defp class_question_text do
    "If you can say what kind of trouble this is, reply with one word — " <>
      "#{class_words_with_glosses()}. If not, no matter: it's logged either way."
  end

  defp class_words_with_glosses do
    Enum.map_join(Grammar.classes(), " · ", fn class ->
      case Map.get(@class_glosses, class) do
        nil -> "`#{class}`"
        gloss -> "`#{class}` (#{gloss})"
      end
    end)
  end

  # A lifecycle phrase (`ack`/`resolved`/`note:`) records in the log but the
  # service returns no command, so without this the act is silent in the thread
  # — you press the button gap 2 taught and nothing shows. Render a light
  # acknowledgment on the 201 so each transition is visible ("reads like the
  # pull"). The `resolved`/`ack`/`closure_note` 201s carry no subject, so the
  # release line names none — the thread already has it.
  defp maybe_ack_lifecycle(%{"event" => "ack"} = event, _body, ctx, thread_id) do
    post_in_thread(ctx, thread_id, "#{mention(event["actor"])} acknowledged · engaging now.")
  end

  # The release line and the question at release are ONE message (ENG-60,
  # andon ADR-0017). Two posts would be two ThreadReplyWorker jobs with no
  # ordering between them, and "Released" arriving after the question reads
  # as a non-sequitur. It is also one ping rather than two, which is the
  # whole friction budget spent where it was meant to go.
  defp maybe_ack_lifecycle(%{"event" => "witness_close"}, body, ctx, thread_id) do
    released = "Released · the hold is cleared."

    case closure_question(body, ctx, thread_id) do
      nil -> post_in_thread(ctx, thread_id, released)
      question -> post_in_thread(ctx, thread_id, released <> "\n" <> question)
    end
  end

  defp maybe_ack_lifecycle(%{"event" => "closure_note"}, _body, ctx, thread_id) do
    post_in_thread(ctx, thread_id, "Closure note logged.")
  end

  # Declining is answering. The wording says so — no "but", no second ask,
  # nothing that reads as disappointment (ENG-49: the tool must not become
  # the burden it exists to surface).
  defp maybe_ack_lifecycle(%{"event" => "closure_note_declined"}, _body, ctx, thread_id) do
    post_in_thread(ctx, thread_id, "Logged as no note — that's an answer. Thanks.")
  end

  defp maybe_ack_lifecycle(%{"event" => "class_provided"} = event, _body, ctx, thread_id) do
    post_in_thread(ctx, thread_id, "Noted — `#{event["class"]}`.")
  end

  defp maybe_ack_lifecycle(_event, _body, _ctx, _thread_id), do: :ok

  # Arms the thread for a plain-words reply and returns the question, or nil
  # where the service asked for none (a replayed release carries no command:
  # one question, asked once).
  defp closure_question(body, ctx, thread_id) do
    with %{"command" => "request_closure_note"} = command <- request_closure_note(body),
         true <- is_integer(thread_id),
         holder when is_binary(holder) <- get_in(command, ["holder", "token"]),
         pull_id when is_binary(pull_id) <- command["pull_id"] do
      NotePrompt.arm(ctx.channel_id, thread_id, pull_id, holder)
      closure_question_text(command["holder"])
    else
      _no_question -> nil
    end
  end

  defp request_closure_note(body) do
    body
    |> Map.get("commands", [])
    |> Enum.find(&(is_map(&1) and &1["command"] == "request_closure_note"))
  end

  # The one question. It asks for both halves at once and teaches the only
  # token it needs — `cause:`, the half nobody can reconstruct weeks later
  # and the one repeat detection groups on. Declining is offered in the same
  # breath so "no" costs no more than "yes".
  defp closure_question_text(holder) do
    "#{mention(holder)} — while it's fresh: what was it? A line is plenty. " <>
      "Add `cause: <your best guess why>` and I'll keep the two apart, which is " <>
      "what lets the retro spot the same cause turning up twice. " <>
      "`no note` is a perfectly good answer."
  end

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

        # The backup inherits the two-timer contract, so they inherit a
        # deadline — and a window nobody states is one that lapses invisibly
        # (ENG-56). Rendered by the same function as the DRI receipt: the
        # obligation is identical, so the sentence should be too.
        post_in_thread(
          ctx,
          thread,
          "Backup #{mention(backup)} — the acknowledge window lapsed; you now carry this pull.\n" <>
            case receipt_due(command) do
              nil -> ""
              due -> due <> "\n"
            end <>
            dri_phrases()
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
              _ =
                update_mirror_row(row, %{
                  status_message_id: message.id,
                  last_watermark: watermark,
                  mirror: mirror
                })

              broadcast_mirror(channel_id, message.id, mirror)

            {:error, reason} ->
              Logger.warning("andon relay: mirror create failed: #{inspect(reason)}")
          end

        status_message_id ->
          case Messaging.edit_message(status_message_id, bot.id, text) do
            {:ok, _} ->
              _ = update_mirror_row(row, %{last_watermark: watermark, mirror: mirror})
              broadcast_mirror(channel_id, status_message_id, mirror)

            {:error, reason} ->
              Logger.warning("andon relay: mirror edit failed: #{inspect(reason)}")
          end
      end

    :ok
  end

  # The text message is the fallback and the notification body; the card reads
  # the snapshot. Anyone already looking at the channel gets it live, and
  # `mirror_for_channel/1` covers whoever arrives between updates.
  defp broadcast_mirror(channel_id, status_message_id, mirror) do
    Phoenix.PubSub.broadcast(
      Slackex.PubSub,
      mirror_topic(channel_id),
      {:andon_mirror, status_message_id, mirror}
    )
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

  # The receipt. Everything a person needs to decide whether to move: who is
  # holding it, what it is about, and when it is owed. The deadline is stated
  # as a time rather than a countdown — a countdown in a chat message is stale
  # the moment it is written, and the absolute time is the fact.
  defp run_command(%{"command" => "notify_dri", "dri" => dri, "thread" => thread} = cmd, ctx) do
    post_in_thread(ctx, thread, receipt_text(dri, cmd) <> "\n" <> dri_phrases())
  end

  # Rendered with the release line rather than on its own (see
  # maybe_ack_lifecycle/4), so there is nothing to do here — but the clause is
  # explicit: a command this relay understands must never look like one it
  # merely failed to recognise.
  defp run_command(%{"command" => "request_closure_note"}, _ctx), do: :ok

  defp run_command(_unknown, _ctx), do: :ok

  # The phrases the DRI can type (ENG-13 gap 2), taught wherever someone
  # becomes the DRI — the initial notify and a backup inheriting the pull. The
  # puller's phrases (`resolved` to release, `withdraw`) are the puller's,
  # taught in the puller confirmation, not here (response-protocol role split).
  # Teaching them is what makes them usable: a word you have to already know
  # offers nothing on its own (Phrases).
  defp receipt_text(dri, cmd) do
    [
      "#{mention(dri)} — you're holding this pull.",
      receipt_subject(cmd),
      receipt_stage(cmd),
      receipt_due(cmd)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp receipt_subject(cmd) do
    case {get_in(cmd, ["subject", "external_id"]), cmd["class"]} do
      {nil, nil} -> nil
      {nil, class} -> "#{class}."
      {subject, nil} -> "#{subject}."
      {subject, class} -> "#{subject} · #{class}."
    end
  end

  defp receipt_stage(%{"stage" => stage}) when is_binary(stage), do: "Stage: #{stage}."
  defp receipt_stage(_), do: nil

  # No clock for this class and stage is a fact worth stating: the alternative
  # is a reader assuming a timer is running when none is.
  #
  # The zone is the service's to supply (ENG-56). The deadline is computed
  # inside the holder's declared hours, so UTC is the one zone it is certainly
  # not owed in — and this relay carries no timezone database, so it cannot
  # convert an instant itself. The service sends the same moment already
  # expressed in the holder's zone; the offset carried in that string is all
  # that is needed to recover the wall clock, and the label is for the reader.
  defp receipt_due(%{"ack_due_local" => local, "ack_due_zone" => zone})
       when is_binary(local) and is_binary(zone) do
    case DateTime.from_iso8601(local) do
      # from_iso8601/1 normalises to UTC and hands back the offset separately,
      # so the wall clock the holder would read is the instant plus its offset.
      {:ok, dt, offset} ->
        wall = DateTime.add(dt, offset, :second)
        "Acknowledge by #{Calendar.strftime(wall, "%H:%M")} #{zone}."

      _ ->
        nil
    end
  end

  # An older service sends the instant alone. Rendering it in UTC is wrong for
  # the reader but not a lie about the moment, and it is what shipped before —
  # so the relay keeps working against a service that has not caught up yet.
  defp receipt_due(%{"ack_due_at" => due}) when is_binary(due) do
    case DateTime.from_iso8601(due) do
      {:ok, dt, _} -> "Acknowledge by #{Calendar.strftime(dt, "%H:%M")} UTC."
      _ -> nil
    end
  end

  defp receipt_due(_), do: "No clock on this one."

  defp dri_phrases do
    "Reply `heard` (or `ack`) to acknowledge · `note: <what> / cause: <why>` once it's addressed."
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

  # Asked when a note arrived without its cause, by either route: a typed
  # `note:` missing one, or the prompted answer to the question at release.
  #
  # It teaches the full `note:` shape rather than a bare `cause:` line, and
  # that is not a style choice — the relay holds no note text between
  # messages, so a lone `cause:` reply parses as ordinary chatter and lands
  # nowhere. The earlier copy ("add a line starting with `cause:` and I'll
  # log both") promised something the relay cannot do. Saying so plainly is
  # the same standard ADR-0017 held the log to: do not assert what you do not
  # know, and do not promise what you will not keep.
  defp cause_prompt_text do
    "Got it — I need the cause alongside it, or the retro cannot tell one " <>
      "cause from another. Send the pair together: " <>
      "`note: <what it was> / cause: <your best guess why>`. " <>
      "Or `no note` — still a fine answer."
  end

  # Reached only when there was no sentence to take (ENG-45 narrowed the
  # corrections; an unknown first word is now a valid bare pull). The register
  # matters: this answers someone reaching for help, so it asks for the one
  # missing thing and demands nothing else — the class can wait.
  defp correction_text do
    "Nearly — tell me what's in your way in one sentence: `pull: <one sentence>`. " <>
      "A class word first (#{Enum.join(Grammar.classes(), ", ")}) helps, but it can wait."
  end

  defp help_text do
    """
    Pull the cord when something is in your way — `pull:` at the start of a message, then one sentence. `pull: I'm stuck` is enough; naming a class sharpens it:
    #{class_lines()}

    Name the item in the sentence (`ENG-123`) and it binds to that work; leave it out and I will ask which.

    If you pulled it: `resolved` when what you flagged is contained · `withdraw` drops one that never bound.
    If it came to you: `heard` to acknowledge · `note: <what it was> / cause: <your best guess>` once it is addressed.

    When a hold is released I ask whoever carried it what it was — once, and only once. Answer in plain words, or `no note`.
    """
  end

  defp class_lines do
    Enum.map_join(Grammar.classes(), "\n", fn class ->
      case Map.get(@class_glosses, class) do
        nil -> "  `pull: #{class} <one sentence>`"
        gloss -> "  `pull: #{class} <one sentence>` — #{gloss}"
      end
    end)
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
