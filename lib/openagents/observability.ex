defmodule OpenAgents.Observability do
  @moduledoc false

  def tool_outcome(_tool_step, _result, _status), do: :ok
  def module_route(_decision), do: :ok
end
