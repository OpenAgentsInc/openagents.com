defmodule OpenAgentsWeb.ControllerSocket do
  @moduledoc """
  Socket for outbound computer-controller connections.

  Authenticated by a computer token in the connect params. The token is
  digest-compared server-side and never logged; the socket carries only the
  computer and owner identifiers.
  """

  use Phoenix.Socket

  alias OpenAgents.Computer
  alias OpenAgents.Machines

  channel "computer:*", OpenAgentsWeb.ComputerChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    with true <- Computer.enabled?(),
         {:ok, machine} <- Machines.authenticate_token(token) do
      {:ok,
       socket
       |> assign(:machine_id, machine.id)
       |> assign(:user_id, machine.user_id)
       |> assign(:token_expires_at, machine.token_expires_at)}
    else
      _denied -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "controller_socket:#{socket.assigns.machine_id}"
end
