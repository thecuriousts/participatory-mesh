defmodule Mesh.TailscaleWatcher do
  @moduledoc """
  Monitors Tailscale network state: peer changes, IP assignments, ACL updates.
  """
  use GenServer
  require Logger

  @poll_interval 15_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :timer.send_interval(@poll_interval, :poll)
    {:ok, %{peers: %{}, status: nil, missing_logged: false}}
  end

  # Public API
  def peers do
    GenServer.call(__MODULE__, :peers, 5_000)
  end

  def peer(ip) do
    GenServer.call(__MODULE__, {:peer, ip}, 5_000)
  end

  def my_ip do
    GenServer.call(__MODULE__, :my_ip, 5_000)
  end

  def acls do
    GenServer.call(__MODULE__, :acls, 5_000)
  end

  @impl true
  def handle_call(:peers, _from, state) do
    {:reply, Map.values(state.peers), state}
  end

  @impl true
  def handle_call({:peer, ip}, _from, state) do
    {:reply, Map.get(state.peers, ip), state}
  end

  @impl true
  def handle_call(:my_ip, _from, state) do
    my_ip = state.status && state.status["Self"] && state.status["Self"]["TailscaleIPs"] 
      |> List.first()
    {:reply, my_ip, state}
  end

  @impl true
  def handle_call(:acls, _from, state) do
    {:reply, state.status && state.status["ACLs"], state}
  end

  @impl true
  def handle_info(:poll, state) do
    case fetch_status() do
      {:ok, status} -> handle_status_update(status, %{state | missing_logged: false})
      {:error, reason} ->
        state =
          if state.missing_logged do
            state
          else
            Logger.warning("tailscale unavailable (#{inspect(reason)}); watcher idle until CLI exists")
            %{state | missing_logged: true}
          end

        {:noreply, state}
    end
  end

  defp fetch_status do
    case System.cmd("tailscale", ["status", "--json"], stderr_to_stdout: true) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, :parse}
        end

      {_out, code} ->
        {:error, code}
    end
  rescue
    error -> {:error, error}
  end

  defp handle_status_update(status, state) do
    old_peers = state.peers
    new_peers = parse_peers(status)
    
    # Detect changes
    added = Map.keys(new_peers) -- Map.keys(old_peers)
    removed = Map.keys(old_peers) -- Map.keys(new_peers)
    changed = Map.keys(new_peers) 
      |> Enum.filter(fn ip -> 
        old = Map.get(old_peers, ip)
        new = Map.get(new_peers, ip)
        old != new
      end)
    
    # Notify changes
    Enum.each(added, &notify_peer_added/1)
    Enum.each(removed, &notify_peer_removed/1)
    Enum.each(changed, &notify_peer_changed/1)
    
    # Update config store
    Mesh.ConfigStore.put("tailscale/peers", new_peers)
    Mesh.ConfigStore.put("tailscale/status", status)
    
    {:noreply, %{state | peers: new_peers, status: status}}
  end

  defp parse_peers(status) do
    peers = status["Peer"] || %{}
    
    Enum.into(peers, %{}, fn {id, peer} ->
      ips = peer["TailscaleIPs"] || []
      primary_ip = List.first(ips)
      
      {primary_ip, %{
        id: id,
        name: peer["HostName"] || id,
        ip: primary_ip,
        ips: ips,
        online: peer["Online"] == true,
        last_seen: peer["LastSeen"],
        os: peer["OS"],
        active: peer["Active"],
        exit_node: peer["ExitNode"] == true,
        tags: peer["Tags"] || []
      }}
    end)
  end

  defp notify_peer_added(ip), do: Logger.info("Tailscale peer added: #{ip}")
  defp notify_peer_removed(ip), do: Logger.info("Tailscale peer removed: #{ip}")
  defp notify_peer_changed(ip), do: Logger.debug("Tailscale peer changed: #{ip}")
end