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

  # client -> server command frames (payload already de-framed by {packet,4}).
  #   0x01                         reseed vortices
  #   0x02  uint16 le n            set vortex count
  #   0x03  uint16 le w, le h      set streamed grid size
  #   0x04  float32 le, le         set circulation (gamma) range
  def handle_info({:tcp, _socket, data}, state) do
    handle_command(data)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _socket, reason}, state), do: {:stop, {:shutdown, reason}, state}

  defp handle_command(<<0x01>>), do: Simulation.reseed()
  defp handle_command(<<0x02, n::unsigned-little-16>>), do: Simulation.set_vortex_count(n)

  defp handle_command(<<0x03, w::unsigned-little-16, h::unsigned-little-16>>),
    do: Simulation.set_grid(w, h)

  defp handle_command(<<0x04, mn::float-little-32, mx::float-little-32>>),
    do: Simulation.set_gamma(mn, mx)

  defp handle_command(other),
    do: Logger.debug("ignoring malformed command: #{inspect(other, limit: 8)}")

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end

  defp fmt_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp fmt_ip(other), do: inspect(other)
end
