defmodule VortexField.Connection do
  @moduledoc """
  One process per connected client. It subscribes to the simulation and
  writes each frame to its socket. The client is not expected to send
  anything; we keep the socket active only to notice a clean disconnect.

  The socket is only activated once the acceptor has transferred ownership
  and sent us `:activate` — otherwise we'd race the `controlling_process`
  hand-off and steal active-mode messages before we actually own the socket.
  """

  use GenServer, restart: :temporary
  require Logger

  alias VortexField.Simulation

  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  @impl true
  def init(socket), do: {:ok, %{socket: socket}}

  @impl true
  def handle_info(:activate, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: true)
    :ok = Simulation.subscribe()

    case :inet.peername(socket) do
      {:ok, {addr, port}} -> Logger.info("client connected: #{fmt_ip(addr)}:#{port}")
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:frame, frame}, %{socket: socket} = state) do
    case :gen_tcp.send(socket, frame) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:shutdown, reason}, state}
    end
  end

  # client sent us something (we don't use it); ignore
  def handle_info({:tcp, _socket, _data}, state), do: {:noreply, state}
  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _socket, reason}, state), do: {:stop, {:shutdown, reason}, state}

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end

  defp fmt_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp fmt_ip(other), do: inspect(other)
end
