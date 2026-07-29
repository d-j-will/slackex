defmodule Slackex.Andon.NotePrompt do
  @moduledoc """
  The question asked at release, and the one reply it will take in plain
  words (andon ENG-60, ADR-0017).

  The service decides *that* a question is owed and *who* owes the answer —
  it pushes `request_closure_note {holder, pull_id, channel, thread}` on a
  fresh release, because only it knows who carries the pull after an
  escalation. What lives here is the relay's half: which thread is listening,
  for whom, and for how long.

  **Armed once.** While a row is unspent, the holder's next message in that
  thread is taken as the answer even though it is ordinary prose — the guard
  that keeps channel chatter out of the log (`Phrases.parse/1` returning
  `:none`) is suspended for exactly one message. It is spent on first use
  whether or not it produced a note, and nothing ever re-arms or re-asks:
  the budget is one question.

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
  Takes the arming if this sender is the one being asked and it has not been
  used. Returns `{:ok, prompt}` having spent it, or `:none`.

  The spend is conditional in SQL, so two replies arriving together cannot
  both be treated as the answer.
  """
  @spec take(integer(), integer(), String.t()) :: {:ok, t()} | :none
  def take(channel_id, thread_id, sender_token) do
    case latest(channel_id, thread_id) do
      %__MODULE__{spent_at: nil, holder_token: ^sender_token} = prompt -> spend(prompt)
      _otherwise -> :none
    end
  end

  defp spend(%__MODULE__{id: id}) do
    query =
      from p in __MODULE__,
        where: p.id == ^id and is_nil(p.spent_at),
        select: p

    case Repo.update_all(query, set: [spent_at: DateTime.utc_now()]) do
      {1, [prompt]} -> {:ok, prompt}
      _lost_the_race -> :none
    end
  end
end
