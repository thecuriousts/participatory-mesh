defmodule Mesh.SyncCoordinator do
  @moduledoc """
  Coordinates Syncthing synchronization across nodes.
  Handles conflict resolution, priority queues, and sync state tracking.
  """
  use GenServer

  @scan_interval 300_000  # 5 minutes
  @conflict_check_interval 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Load folder configs from config store
    folders = load_folder_configs()
    
    :timer.send_interval(@scan_interval, :scan_all)
    :timer.send_interval(@conflict_check_interval, :check_conflicts)
    
    {:ok, %{
      folders: folders,
      conflicts: :queue.new(),
      pending_scans: MapSet.new(),
      last_scan: %{}
    }}
  end

  # Public API
  def scan_folder(folder_id) do
    GenServer.cast(__MODULE__, {:scan_folder, folder_id})
  end

  def scan_all do
    GenServer.cast(__MODULE__, :scan_all)
  end

  def get_conflicts do
    GenServer.call(__MODULE__, :get_conflicts, 5_000)
  end

  def resolve_conflict(conflict_id, resolution) do
    GenServer.call(__MODULE__, {:resolve_conflict, conflict_id, resolution}, 5_000)
  end

  def folder_status(folder_id) do
    GenServer.call(__MODULE__, {:folder_status, folder_id}, 5_000)
  end

  def all_folders_status do
    GenServer.call(__MODULE__, :all_folders_status, 5_000)
  end

  @impl true
  def handle_cast({:scan_folder, folder_id}, state) do
    trigger_scan(folder_id)
    {:noreply, %{state | pending_scans: MapSet.put(state.pending_scans, folder_id)}}
  end

  @impl true
  def handle_cast(:scan_all, state) do
    Enum.each(state.folders, fn {id, _config} -> trigger_scan(id) end)
    {:noreply, %{state | pending_scans: MapSet.new(MapSet.to_list(state.pending_scans) ++ Map.keys(state.folders))}}
  end

  @impl true
  def handle_call(:get_conflicts, _from, state) do
    conflicts = :queue.to_list(state.conflicts)
    {:reply, conflicts, state}
  end

  @impl true
  def handle_call({:resolve_conflict, conflict_id, resolution}, _from, state) do
    case find_conflict(state.conflicts, conflict_id) do
      nil -> {:reply, {:error, :not_found}, state}
      conflict ->
        apply_resolution(conflict, resolution)
        new_conflicts = remove_conflict(state.conflicts, conflict_id)
        {:reply, :ok, %{state | conflicts: new_conflicts}}
    end
  end

  @impl true
  def handle_call({:folder_status, folder_id}, _from, state) do
    status = get_folder_status(folder_id)
    {:reply, status, state}
  end

  @impl true
  def handle_call(:all_folders_status, _from, state) do
    statuses = Enum.map(Map.keys(state.folders), &get_folder_status/1)
    {:reply, statuses, state}
  end

  @impl true
  def handle_info(:scan_all, state) do
    scan_all()
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_conflicts, state) do
    check_conflicts()
    {:noreply, state}
  end

  @impl true
  def handle_info({:syncthing_event, event}, state) do
    handle_syncthing_event(event, state)
  end

  # Internal functions
  defp load_folder_configs do
    case Mesh.ConfigStore.get("syncthing/folders") do
      {:ok, folders} when is_map(folders) -> folders
      _ -> %{}
    end
  end

  defp trigger_scan(folder_id) do
    Mesh.CommandFabric.broadcast(:trigger_syncthing_scan, [folder: folder_id])
  end

  defp get_folder_status(folder_id) do
    case Mesh.CommandFabric.call(node(), :syncthing_status, []) do
      {:ok, status} ->
        folder = Map.get(status.folders, folder_id)
        %{id: folder_id, status: folder}
      {:error, e} ->
        %{id: folder_id, error: e}
    end
  end

  defp check_conflicts do
    Enum.each(Node.list() ++ [node()], fn n ->
      Mesh.CommandFabric.cast(n, :syncthing_status)
      # In real impl, would parse conflicts from status
    end)
  end

  defp handle_syncthing_event(%{type: "FolderConflict", data: data}, state) do
    conflict = %{
      id: "conflict_#{System.unique_integer([:positive])}",
      folder: data.folder,
      file: data.file,
      local_mtime: data.local_mtime,
      remote_mtime: data.remote_mtime,
      local_size: data.local_size,
      remote_size: data.remote_size,
      detected_at: DateTime.utc_now()
    }
    
    new_conflicts = :queue.in(conflict, state.conflicts)
    Mesh.ConfigStore.put("syncthing/conflicts/#{conflict.id}", conflict)
    
    {:noreply, %{state | conflicts: new_conflicts}}
  end

  defp handle_syncthing_event(_event, state) do
    {:noreply, state}
  end

  defp find_conflict(queue, id) do
    :queue.to_list(queue) |> Enum.find(fn c -> c.id == id end)
  end

  defp remove_conflict(queue, id) do
    :queue.to_list(queue) |> Enum.filter(fn c -> c.id != id end) |> :queue.from_list()
  end

  defp apply_resolution(conflict, resolution) do
    strategy = resolution.strategy || :newest
    target_device = resolution.target_device
    
    action = case strategy do
      :newest -> 
        if conflict.local_mtime > conflict.remote_mtime do :keep_local else :keep_remote end
      :local_wins -> :keep_local
      :remote_wins -> :keep_remote
      :manual -> :manual
    end
    
    # Tell Syncthing to resolve
    Mesh.CommandFabric.broadcast(:resolve_syncthing_conflict, [
      folder: conflict.folder,
      file: conflict.file,
      action: action,
      device: target_device
    ])
  end
end