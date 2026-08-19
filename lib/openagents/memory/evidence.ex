defmodule OpenAgents.Memory.Evidence do
  @moduledoc false

  def valid_usage_ledger?(%{}), do: true
  def valid_usage_ledger?(_), do: false

  def normalize_usage_items(items) when is_list(items), do: {:ok, items}
  def normalize_usage_items(_), do: {:ok, []}
end
