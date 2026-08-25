defmodule OpenAgents.Gym.Trial do
  @moduledoc """
  One task of a run: its name, its state, and — on the thread lane — the
  thread the coder opened for it.

  A trial is upserted by `(run_id, task)`: the harness reports `running`
  when the trial starts and reports again when the grade lands, and both
  reports name the same row. `thread_id` is the link between the Gym and
  the transcript that already streams through this server; it is verified
  against the bearer's account at ingest (`OpenAgents.Gym.record_trial/3`)
  and carries no foreign key, because a thread may be deleted with its
  account while the benchmark record stays. Local-lane trials have no
  thread and leave it nil — expected, not an error.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OpenAgents.Gym.Run

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(running passed failed ungraded)

  schema "gym_trials" do
    belongs_to :run, Run
    field :task, :string
    field :state, :string
    field :thread_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def states, do: @states

  @doc """
  One trial report. `run_id` is set by the context, never cast from a
  caller, and the thread-ownership check lives in the context beside the
  account it needs.
  """
  def changeset(trial, attributes) do
    trial
    |> cast(attributes, [:task, :state, :thread_id])
    |> validate_required([:task, :state])
    |> validate_length(:task, min: 1, max: 200, count: :bytes)
    |> validate_inclusion(:state, @states)
    |> check_constraint(:task, name: :gym_trials_task_bound_check)
    |> check_constraint(:state, name: :gym_trials_state_check)
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:run_id, :task])
  end
end
