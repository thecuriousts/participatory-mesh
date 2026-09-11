defmodule Mesh.HealthMonitor do
  @moduledoc """
  Cluster health monitoring: node heartbeats, split-brain detection, service health.
  """
  use GenServer
  require Logger

  @check_interval 10_000
  @peer_timeout 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Start with known peers
    peers = MapSet.new([node() | Node.list()])
    
    :timer.send_interval(@check_interval, :check_peers)
    :timer.send_interval(60_000, :check_split_brain)
    
    {:ok, %{
      peers: peers,
      last_seen: Map.new(peers, fn p -> {p, DateTime.utc_now()} end),
      down: MapSet.new(),
      split_brain: false,
      history: :queue.new()
    }}
  end

  # Public API
  def cluster_status do
    GenServer.call(__MODULE__, :status, 5_000)
  end

  def peer_status(peer) do
    GenServer.call(__MODULE__, {:peer_status, peer}, 5_000)
  end

  def is_healthy?(peer) do
    case peer_status(peer) do
      {:ok, %{status: :up}} -> true
      _ -> false
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    peers = MapSet.to_list(state.peers)
    statuses = Enum.map(peers, fn p ->
      last_seen = Map.get(state.last_seen, p)
      status = if last_seen && DateTime.diff(DateTime.utc_now(), last_seen) < @peer_timeout * 2 do
        :up
      else
        :down
      end
      {p, %{status: status, last_seen: last_seen}}
    end)
    
    {:reply, %{
      self: to_string(node()),
      peers: Map.new(statuses, fn {p, meta} -> {to_string(p), stringify_meta(meta)} end),
      down: Enum.map(MapSet.to_list(state.down), &to_string/1),
      split_brain: state.split_brain,
      quorum: quorum_check(state)
    }, state}
  end

  @impl true
  def handle_call({:peer_status, peer}, _from, state) do
    last_seen = Map.get(state.last_seen, peer)
    status = if last_seen && DateTime.diff(DateTime.utc_now(), last_seen) < @peer_timeout * 2 do
      :up
    else
      :down
    end
    {:reply, {:ok, %{status: status, last_seen: last_seen}}, state}
  end

  @impl true
  def handle_info(:check_peers, state) do
    current_peers = MapSet.new([node() | Node.list()])
    
    # Detect new peers
    new_peers = MapSet.difference(current_peers, state.peers)
    Enum.each(new_peers, fn p ->
      Logger.info("New peer discovered: #{p}")
      Mesh.CommandFabric.cast(p, :health_check)
    end)
    
    # Check existing peers
    alive_peers = Enum.filter(current_peers, &Node.ping/1)
    now = DateTime.utc_now()
    
    new_last_seen = Enum.reduce(alive_peers, state.last_seen, fn p, acc ->
      Map.put(acc, p, now)
    end)
    
    # Detect down peers
    down_peers = MapSet.difference(state.peers, MapSet.new(alive_peers))
    new_down = MapSet.difference(down_peers, state.down)
    
    Enum.each(new_down, fn p ->
      Logger.warning("Peer down: #{p}")
      Mesh.ServiceRegistry.unregister_local_service(p)
      notify_down(p)
    end)
    
    # Detect recovered peers
    recovered = MapSet.difference(state.down, down_peers)
    Enum.each(recovered, fn p ->
      Logger.info("Peer recovered: #{p}")
      notify_recovered(p)
    end)
    
    new_state = state
    |> Map.put(:peers, current_peers)
    |> Map.put(:last_seen, new_last_seen)
    |> Map.put(:down, down_peers)
    
    {:noreply, record_event(new_state, :peer_check, %{
      alive: alive_peers,
      down: MapSet.to_list(down_peers)
    })}
  end

  @impl true
  def handle_info(:check_split_brain, state) do
    # Check if we can reach majority of known peers
    total_peers = MapSet.size(state.peers)
    reachable = Enum.count(state.peers, &Node.ping/1)
    
    # Split brain if we can't reach majority (but we're not alone)
    new_split_brain = total_peers > 1 && reachable < div(total_peers, 2) + 1
    
    if new_split_brain != state.split_brain do
      Logger.warning("Split brain #{if(new_split_brain, do: "detected", else: "resolved")}: #{reachable}/#{total_peers} reachable")
      if new_split_brain do
        notify_split_brain(state.peers)
      end
    end
    
    {:noreply, %{state | split_brain: new_split_brain} 
      |> record_event(:split_brain_check, %{reachable: reachable, total: total_peers})}
  end

  @impl true
  def handle_info({:peer_heartbeat, peer}, state) do
    new_state = %{state | last_seen: Map.put(state.last_seen, peer, DateTime.utc_now())}
    {:noreply, new_state}
  end

  defp stringify_meta(meta) do
    last = meta[:last_seen]

    %{
      status: meta.status,
      last_seen: if(last, do: DateTime.to_iso8601(last), else: nil)
    }
  end

  defp peer_fresh?(peer, state) do
    case Map.get(state.last_seen, peer) do
      nil -> false
      last -> DateTime.diff(DateTime.utc_now(), last) < @peer_timeout
    end
  end

  defp quorum_check(state) do
    total = MapSet.size(state.peers)
    up = Enum.count(state.peers, fn p -> peer_fresh?(p, state) end)
    %{total: total, up: up, has_quorum: up >= div(total, 2) + 1}
  end

  defp notify_down(peer) do
    Mesh.ConfigStore.put("cluster/peers/#{peer}/status", :down)
    Mesh.CommandFabric.broadcast(:peer_down, [peer])
  end

  defp notify_recovered(peer) do
    Mesh.ConfigStore.put("cluster/peers/#{peer}/status", :up)
    Mesh.CommandFabric.broadcast(:peer_up, [peer])
  end

  defp notify_split_brain(peers) do
    Mesh.ConfigStore.put("cluster/split_brain", true)
    Mesh.ConfigStore.put("cluster/partition", Enum.to_list(peers))
    Mesh.CommandFabric.broadcast(:split_brain, [Enum.to_list(peers)])
  end

  defp record_event(state, event, data) do
    history = :queue.in({DateTime.utc_now(), event, data}, state.history)
    # Keep last 100 events
    history = if :queue.len(history) > 100, do: :queue.drop(history), else: history
    %{state | history: history}
  end
end