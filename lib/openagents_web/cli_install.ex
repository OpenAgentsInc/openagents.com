defmodule OpenAgentsWeb.CliInstall do
  @moduledoc """
  The published install command for each shell.

  Unix readers pipe `install.sh` into `sh`. Windows PowerShell has no `sh`,
  and its `curl` is `Invoke-WebRequest`, which does not accept `-fsSL`.
  Windows readers run `install.ps1` through `irm | iex`.
  """

  @unix "curl -fsSL https://openagents.com/install.sh | sh"
  @windows "irm https://openagents.com/install.ps1 | iex"

  def unix, do: @unix
  def windows, do: @windows
end
