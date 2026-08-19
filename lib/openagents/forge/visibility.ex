defmodule OpenAgents.Forge.Visibility do
  @moduledoc false

  def allows?(repo, _level) when is_binary(repo), do: true
  def allows?(_, _), do: false

  def repo_path(_repo), do: ""
end
