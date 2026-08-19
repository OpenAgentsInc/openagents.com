defmodule OpenAgents.Work.Job do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "work_jobs" do
    field :status, :string
    field :error_code, :string
    field :tool_call_count, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps()
  end
end
