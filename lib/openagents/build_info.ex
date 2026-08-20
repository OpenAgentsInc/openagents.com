defmodule OpenAgents.BuildInfo do
  @moduledoc """
  Compiled-in build revision — the demo leaf module of the hot-load lane.
  It is on the starter hot-load allowlist precisely because it is trivial and
  dependency-free: a hot deploy swaps the whole module, so an edit changes
  `@revision` and status shows it fleet-wide in seconds.
  """

  @revision System.get_env("OPENAGENTS_BUILD_REVISION", "image")

  @doc "The compiled-in revision string of this module."
  def revision, do: @revision

  @doc "When this module was hot-loaded, or nil for the boot image version."
  def loaded_at, do: nil

  @doc "The immutable runtime image digest, or nil outside a packaged image."
  def image_digest, do: Application.get_env(:openagents, :image_digest)
end
