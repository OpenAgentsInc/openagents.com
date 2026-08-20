defmodule OpenAgents.Forge.GitHTTP do
  @moduledoc """
  Stub git HTTP plug used to keep the lifted Sarah forge tests compiling while
  the runtime is stubbed out.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: conn
end
