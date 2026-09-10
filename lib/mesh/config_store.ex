defmodule Mesh.ConfigStore do
  @moduledoc """
  In-memory config with optional RPC merge to connected nodes.
  Mnesia is not on the boot path at n=2; Syncthing already replicates files.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{entries: %{}, subscribers: []}}
  end

  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value}, 5_000)
  def get(key), do: GenServer.call(__MODULE__, {:get, key}, 5_000)
  def delete(key), do: GenServer.call(__MODULE__, {:delete, key}, 5_000)
  def all, do: GenServer.call(__MODULE__, :all, 5_000)
  def subscribe(pattern), do: GenServer.call(__MODULE__, {:subscribe, pattern}, 5_000)
  def dump_entries, do: GenServer.call(__MODULE__, :dump, 5_000)

  def sync_from_peers do
    GenServer.cast(__MODULE__, :sync)
  end

  def handle_config_change(changed, removed) do
    Enum.each(changed, fn {key, value} -> put(key, value) end)
    Enum.each(removed, fn key -> delete(key) end)
    :ok
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    entry = %{
      value: value,
      version: next_version(state.entries, key),
      updated_at: DateTime.utc_now(),
      updated_by: node()
    }

    entries = Map.put(state.entries, key, entry)
    fanout({:merge, key, entry})
    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:get, key}, _from, state) do
    reply =
      case Map.get(state.entries, key) do
        nil -> {:error, :not_found}
        %{value: value} -> {:ok, value}
      end

    {:reply, reply, state}
  end

  def handle_call(:all, _from, state) do
    configs = Map.new(state.entries, fn {k, %{value: v}} -> {k, v} end)
    {:reply, configs, state}
  end

  def handle_call({:delete, key}, _from, state) do
    fanout({:drop, key})
    {:reply, :ok, %{state | entries: Map.delete(state.entries, key)}}
  end

  def handle_call({:subscribe, pattern}, _from, state) do
    {:reply, :ok, %{state | subscribers: [pattern | state.subscribers]}}
  end

  def handle_call(:dump, _from, state) do
    {:reply, state.entries, state}
  end

  @impl true
  def handle_cast(:sync, state) do
    entries =
      Enum.reduce(Node.list(), state.entries, fn peer, acc ->
        case :rpc.call(peer, __MODULE__, :dump_entries, [], 5_000) do
          {:badrpc, _} -> acc
          remote when is_map(remote) -> merge_all(acc, remote)
          _ -> acc
        end
      end)

    {:noreply, %{state | entries: entries}}
  end

  def handle_cast({:merge, key, remote}, state) do
    local = Map.get(state.entries, key)

    entries =
      if should_apply?(local, remote) do
        Map.put(state.entries, key, remote)
      else
        state.entries
      end

    {:noreply, %{state | entries: entries}}
  end

  def handle_cast({:drop, key}, state) do
    {:noreply, %{state | entries: Map.delete(state.entries, key)}}
  end

  defp next_version(entries, key) do
    case Map.get(entries, key) do
      nil -> 1
      %{version: v} -> v + 1
    end
  end

  defp should_apply?(nil, _remote), do: true

  defp should_apply?(local, remote) do
    remote.version > local.version or
      (remote.version == local.version and remote.updated_by > local.updated_by)
  end

  defp merge_all(local, remote) do
    Enum.reduce(remote, local, fn {key, entry}, acc ->
      if should_apply?(Map.get(acc, key), entry), do: Map.put(acc, key, entry), else: acc
    end)
  end

  defp fanout(msg) do
    Enum.each(Node.list(), fn n ->
      GenServer.cast({__MODULE__, n}, msg)
    end)
  end
end
