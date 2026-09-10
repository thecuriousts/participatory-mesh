defmodule Mesh.ServiceRegistry do
  @moduledoc """
  Local service table (per node). At n=2, `Node.list` + RPC is enough;
  Horde is not on the boot path.
  """
  use GenServer

  @default_services %{
    syncthing: %{port: 8384, health: :unknown, endpoint: "/rest/system/status"},
    ssh: %{port: 22, health: :unknown, endpoint: nil},
    tailscale: %{port: 0, health: :unknown, endpoint: nil}
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    now = DateTime.utc_now()

    services =
      Map.new(@default_services, fn {name, meta} ->
        {{node(), name}, Map.merge(meta, %{node: node(), registered_at: now})}
      end)

    :timer.send_interval(30_000, :check_health)
    {:ok, %{services: services}}
  end

  def register_local_service(name, meta \\ %{}) do
    GenServer.call(__MODULE__, {:register, name, meta})
  end

  def unregister_local_service(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  def all_services do
    GenServer.call(__MODULE__, :all, 5_000)
  end

  def services_on_node(target_node) do
    all_services()
    |> Map.get(target_node, [])
  end

  def service_status(name) do
    GenServer.call(__MODULE__, {:status, name}, 5_000)
  end

  def healthy_services do
    all_services()
    |> Enum.flat_map(fn {_node, services} -> services end)
    |> Enum.filter(fn {_name, meta} -> meta.health == :healthy end)
    |> Enum.map(fn {name, _meta} -> name end)
  end

  def unhealthy_nodes do
    all_services()
    |> Enum.filter(fn {_node, services} ->
      Enum.any?(services, fn {_name, meta} -> meta.health == :unhealthy end)
    end)
    |> Enum.map(fn {node, _} -> node end)
  end

  @impl true
  def handle_call({:register, name, meta}, _from, state) do
    full =
      Map.get(@default_services, name, %{})
      |> Map.merge(meta)
      |> Map.put(:node, node())
      |> Map.put(:registered_at, DateTime.utc_now())

    services = Map.put(state.services, {node(), name}, full)
    {:reply, :ok, %{state | services: services}}
  end

  def handle_call({:unregister, name}, _from, state) do
    {:reply, :ok, %{state | services: Map.delete(state.services, {node(), name})}}
  end

  def handle_call(:all, _from, state) do
    grouped =
      state.services
      |> Enum.group_by(fn {{n, _name}, _meta} -> n end, fn {{_n, name}, meta} -> {name, meta} end)

    {:reply, grouped, state}
  end

  def handle_call({:status, name}, _from, state) do
    reply =
      case Map.get(state.services, {node(), name}) do
        nil -> {:error, :not_found}
        meta -> {:ok, meta}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:check_health, state) do
    services =
      Enum.reduce(Map.keys(@default_services), state.services, fn name, acc ->
        health = check_service_health(name)

        Map.update(acc, {node(), name}, %{health: health}, fn meta ->
          meta
          |> Map.put(:health, health)
          |> Map.put(:last_check, DateTime.utc_now())
        end)
      end)

    {:noreply, %{state | services: services}}
  end

  defp check_service_health(:syncthing) do
    case Req.get("http://127.0.0.1:8384/rest/system/status", receive_timeout: 500, retry: false) do
      {:ok, %{status: 200}} -> :healthy
      _ -> :unhealthy
    end
  rescue
    _ -> :unhealthy
  end

  defp check_service_health(:ssh) do
    case :gen_tcp.connect(~c"127.0.0.1", 22, [:inet], 1_000) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :healthy

      _ ->
        :unhealthy
    end
  end

  defp check_service_health(:tailscale) do
    case System.cmd("tailscale", ["status", "--json"], stderr_to_stdout: true) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, %{"BackendState" => "Running"}} -> :healthy
          _ -> :unhealthy
        end

      _ ->
        :unhealthy
    end
  rescue
    _ -> :unhealthy
  end
end
