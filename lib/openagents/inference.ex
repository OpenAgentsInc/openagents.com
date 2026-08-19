defmodule OpenAgents.Inference do
  @moduledoc false

  def resolve(_token), do: {:ok, %{}}
  def record_usage(_grant, _usage), do: :ok
end
