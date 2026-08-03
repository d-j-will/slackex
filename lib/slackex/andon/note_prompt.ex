defmodule Slackex.Andon.NotePrompt do
  @moduledoc """
  The question asked at release, and the one reply it will take in plain
  words (andon ENG-60, ADR-0017).

  The service decides *that* a question is owed and *who* owes the answer —
  it pushes `request_closure_note {holder, pull_id, channel, thread}` on a
  fresh release, because only it knows who carries the pull after an
  escalation. What lives here is the relay's half: which thread is listening,
  for whom, and for how long.

  **Armed until answered.** While a row is unspent, the holder's messages in
  that thread are read as the answer even though they are ordinary prose —
  the guard that keeps channel chatter out of the log (`Phrases.parse/1`
  returning `:none`) is suspended. The arming is spent by a closure act
  landing (a note, or a decline), never by an attempt that recorded nothing:
  ADR-0017 spent it on first use either way, and the field showed that
  handing someone a corrective prompt they no longer had an arming to use
  was a dead end (andon ENG-74, ADR-0019).

  **Asked once, corrected once.** Nothing re-asks — the friction budget is
  one question, and `prompted_at` bounds the correction to one reply so an
  open arming is not a standing nag. After that the relay is silent and
  still listening.

  The row outlives its arming on purpose. A `note:` typed in the thread days
  later still needs the pull id to address the right closed pull, and a
  thread that has carried two pulls has two rows — the most recent one names
  the pull the last question was about.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Slackex.Repo

  @type t :: %__MODULE__{}

  schema "andon_note_prompts" do
    field :channel_id, :integer
    field :thread_id, :integer
    field :pull_id, :string
    field :holder_token, :string
    field :spent_at, :utc_datetime_usec
    field :prompted_at, :utc_datetime_usec
    field :partial_note, :string
    field :partial_cause, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Records that the question was asked. Idempotent on the pull: a redelivered
  release must not re-arm a prompt the holder already answered or ignored.
  """
  @spec arm(integer(), integer(), String.t(), String.t()) :: :ok
  def arm(channel_id, thread_id, pull_id, holder_token) do
    %__MODULE__{}
    |> cast(
      %{
        channel_id: channel_id,
        thread_id: thread_id,
        pull_id: pull_id,
        holder_token: holder_token
      },
      [:channel_id, :thread_id, :pull_id, :holder_token]
    )
    |> validate_required([:channel_id, :thread_id, :pull_id, :holder_token])
    |> Repo.insert(on_conflict: :nothing, conflict_target: :pull_id)

    :ok
  end

  @doc """
  Keeps the half of an answer that did arrive, so the next message only has
  to carry the other one.

  Merges rather than overwrites: someone who gives the cause, is asked what
  it was, and then answers with prose has supplied both halves across two
  messages, and neither should be lost because they arrived separately.
  """
  @spec keep(t(), String.t() | nil, String.t() | nil) :: {:ok, t()}
  def keep(%__MODULE__{} = prompt, note, cause) do
    prompt
    |> cast(
      %{
        partial_note: note || prompt.partial_note,
        partial_cause: cause || prompt.partial_cause
      },
      [:partial_note, :partial_cause]
    )
    |> Repo.update()
  end

  @doc """
  The thread's most recent question, spent or not, or nil. This is what any
  closure act in the thread addresses its pull by — the answer echoes the
  `pull_id` back so the service does not have to guess which closed pull the
  thread means.
  """
  @spec latest(integer(), integer()) :: t() | nil
  def latest(channel_id, thread_id) do
    Repo.one(
      from p in __MODULE__,
        where: p.channel_id == ^channel_id and p.thread_id == ^thread_id,
        order_by: [desc: p.id],
        limit: 1
    )
  end

  @doc """
  The live arming for this sender, if the question was addressed to them and
  no answer has landed yet. Reads only — spending is what a *record* does.
  """
  @spec pending(integer(), integer(), String.t()) :: {:ok, t()} | :none
  def pending(channel_id, thread_id, sender_token) do
    case latest(channel_id, thread_id) do
      %__MODULE__{spent_at: nil, holder_token: ^sender_token} = prompt -> {:ok, prompt}
      _otherwise -> :none
    end
  end

  @doc """
  Spends the arming. Returns `{:ok, prompt}` to whoever won, `:none` to
  anyone who did not.

  Conditional in SQL because that is the only thing standing between two
  replies arriving together and two closure notes for one pull — and both
  relay replicas process every channel message, so "together" is not
  hypothetical.
  """
  @spec spend(t()) :: {:ok, t()} | :none
  def spend(%__MODULE__{id: id}), do: stamp(id, :spent_at)

  @doc """
  Spends whatever arming this thread has left, because a closure act landed.

  Called on the 201, so the log records the note before the relay stops
  listening. Covers the typed `note:` and `no note` paths, which never went
  near the arming — reaching a closure act by a route that did not need it
  still answers the question.
  """
  @spec close(integer(), integer()) :: :ok
  def close(channel_id, thread_id) do
    with %__MODULE__{spent_at: nil} = prompt <- latest(channel_id, thread_id),
         {:ok, _spent} <- spend(prompt) do
      :ok
    else
      # No question here, or it was already answered — either way, closed.
      _nothing_to_close -> :ok
    end
  end

  @doc """
  Claims the one correction this arming gets. `{:ok, prompt}` the first time,
  `:none` after — an arming that outlives a mistake must not turn into a bot
  asking for a cause on every message the holder sends.
  """
  @spec mark_prompted(t()) :: {:ok, t()} | :none
  def mark_prompted(%__MODULE__{id: id}), do: stamp(id, :prompted_at)

  defp stamp(id, field) do
    query =
      from p in __MODULE__,
        where: p.id == ^id and is_nil(field(p, ^field)),
        select: p

    case Repo.update_all(query, set: [{field, DateTime.utc_now()}]) do
      {1, [prompt]} -> {:ok, prompt}
      _lost_the_race -> :none
    end
  end
end
