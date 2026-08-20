defmodule OpenAgents.Turns do
  @moduledoc """
  Turn lifecycle stub for the Sarah chat cutover.

  The real turn execution pipeline is deferred until the inference and tool
  runtimes are fully wired. For now `start/1` reports success so the chat UI
  compiles and the form resets, while `cancel/1` is a no-op that lets the
  composer continue to be usable.
  """

  def start(_turn_id), do: {:ok, nil}

  def cancel(_turn_id), do: :ok
end
