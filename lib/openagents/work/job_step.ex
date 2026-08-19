defmodule OpenAgents.Work.JobStep do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "work_job_steps" do
    field :work_job_id, :binary_id
    field :status, :string
    timestamps()
  end
end
