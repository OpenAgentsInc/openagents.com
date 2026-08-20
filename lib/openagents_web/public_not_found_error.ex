defmodule OpenAgentsWeb.PublicNotFoundError do
  @moduledoc """
  Raised by the public transparency surfaces when a repo, ref, path, or sha
  is unknown — or when a repo's disclosure level does not admit the surface
  at all (TRANSPARENCY-001). Renders as a plain 404: an unconfigured repo
  and a nonexistent one are deliberately indistinguishable from outside.
  """

  defexception message: "not found", plug_status: 404
end
