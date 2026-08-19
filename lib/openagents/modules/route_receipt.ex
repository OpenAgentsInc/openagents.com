defmodule OpenAgents.Modules.RouteReceipt do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "module_route_receipts" do
    timestamps()
  end
end
