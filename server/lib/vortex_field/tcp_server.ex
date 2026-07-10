defmodule VortexField.TcpServer do
  @moduledoc """
  Listens on the configured TCP port and hands each accepted socket to a
  supervised `VortexField.Connection`. The listen socket uses `{packet, 4}`
  so every `:gen_tcp.send/2` is automatically length-prefixed (4-byte BE).
  """

  use GenServer
  require Logger

  alias VortexField.{Config, Connection}

  @conn_sup VortexField.ConnectionSupervisor

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    port = Config.get(:port)

    listen_opts = [
      :binary,
      packet: 4,
      active: false,
      reuseaddr: true,
      nodelay: true,
      backlog: 16
    ]

    {:ok, lsock} = :gen_tcp.listen(port, listen_opts)
    Logger.info("listening on tcp/#{port}")
    send(self(), :accept)
    {:ok, %{lsock: lsock}}
  end

  @impl true
  def handle_info(:accept, %{lsock: lsock} = state) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        {:ok, pid} = DynamicSupervisor.start_child(@conn_sup, {Connection, sock})
        :ok = :gen_tcp.controlling_process(sock, pid)
        send(pid, :activate)
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("accept failed: #{inspect(reason)}")
        send(self(), :accept)
        {:noreply, state}
    end
  end
end
