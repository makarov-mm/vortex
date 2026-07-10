defmodule VortexField.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: VortexField.Registry},
      {DynamicSupervisor, name: VortexField.ConnectionSupervisor, strategy: :one_for_one},
      VortexField.Simulation,
      VortexField.TcpServer
    ]

    opts = [strategy: :one_for_one, name: VortexField.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
