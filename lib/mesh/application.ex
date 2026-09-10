defmodule Mesh.Application do
  @moduledoc """
  Supervision tree for the mesh coordination kernel.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Mesh.ConfigStore,
      Mesh.ServiceRegistry,
      Mesh.CommandFabric,
      Mesh.HealthMonitor,
      Mesh.SyncCoordinator,
      Mesh.TailscaleWatcher,
      Mesh.WebServer
    ]

    opts = [strategy: :one_for_one, name: Mesh.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Mesh.ConfigStore.handle_config_change(changed, removed)
    :ok
  end
end
