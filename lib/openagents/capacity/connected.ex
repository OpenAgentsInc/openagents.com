defmodule OpenAgents.Capacity.Connected do
  @moduledoc false

  import Ecto.Query

  alias OpenAgents.Conversations.{Visitor}
  alias OpenAgents.Machines
  alias OpenAgents.Repo
  alias OpenAgents.Work.Job

  @behaviour OpenAgents.Capacity.Evidence

  @impl true
  def fetch(%{id: user_id}) when is_binary(user_id) do
    machines = Machines.list_machines(user_id)
    logical = length(machines)
    machine_ids = Enum.map(machines, & &1.id)

    active_reservations =
      Repo.aggregate(
        from(job in Job,
          join: visitor in Visitor,
          on: visitor.id == job.owner_visitor_id,
          where:
            visitor.user_id == ^user_id and job.machine_id in ^machine_ids and
              job.status in ["queued", "running"]
        ),
        :count
      )

    queued =
      Repo.aggregate(
        from(job in Job,
          join: visitor in Visitor,
          on: visitor.id == job.owner_visitor_id,
          where:
            visitor.user_id == ^user_id and job.machine_id in ^machine_ids and
              job.status == "queued"
        ),
        :count
      )

    observed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {:ok,
     %{
       "classes" => [
         %{
           "id" => "connected",
           "logical" => logical,
           "active_reservations" => active_reservations,
           "reported_free" => max(logical - active_reservations, 0),
           "queued" => queued,
           "observed_limit" => logical,
           "observed_at" => observed_at,
           "estimated_wait_seconds" => %{"low" => 0, "high" => 0}
         }
       ]
     }}
  end

  def fetch(_viewer), do: {:error, :invalid_viewer}
end
