defmodule Mesh.WebServer do
  @moduledoc """
  HTTP API and dashboard for the mesh cluster.
  """
  use GenServer
  import Plug.Conn

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = http_port()

    children = [
      {Plug.Cowboy, scheme: :http, plug: Mesh.WebServer.Router, options: [port: port]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Mesh.WebServer.Supervisor)
    {:ok, %{}}
  end

  defmodule Router do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_header("content-type", "application/json")
      |> Mesh.WebServer.route()
    end
  end

  def route(conn), do: do_route(conn)

  defp http_port do
    cond do
      port = System.get_env("MESH_WEB_PORT") -> String.to_integer(port)
      port = get_in(Application.get_env(:mesh, :web_server, []), [:port]) -> port
      true -> 47989
    end
  end

  defp do_route(%Plug.Conn{request_path: "/health"} = conn) do
    status = Mesh.HealthMonitor.cluster_status()
    json(conn, 200, status)
  end

  defp do_route(%Plug.Conn{request_path: "/peers"} = conn) do
    peers = Mesh.TailscaleWatcher.peers()
    json(conn, 200, %{peers: peers})
  end

  defp do_route(%Plug.Conn{request_path: "/services"} = conn) do
    services = Mesh.ServiceRegistry.all_services()
    json(conn, 200, %{services: services})
  end

  defp do_route(%Plug.Conn{request_path: "/config"} = conn) do
    config = Mesh.ConfigStore.all()
    json(conn, 200, %{config: config})
  end

  defp do_route(%Plug.Conn{request_path: "/folders"} = conn) do
    folders = Mesh.SyncCoordinator.all_folders_status()
    json(conn, 200, %{folders: folders})
  end

  defp do_route(%Plug.Conn{request_path: "/conflicts"} = conn) do
    conflicts = Mesh.SyncCoordinator.get_conflicts()
    json(conn, 200, %{conflicts: conflicts})
  end

  defp do_route(%Plug.Conn{request_path: "/command", method: "POST"} = conn) do
    case Mesh.Auth.check(conn) do
      {:error, :token_not_configured} ->
        json(conn, 401, %{error: "token_not_configured"})

      {:error, :unauthorized} ->
        json(conn, 401, %{error: "unauthorized"})

      :ok ->
        dispatch_command(conn)
    end
  end

  defp do_route(%Plug.Conn{request_path: "/command/help"} = conn) do
    {:ok, help} = Mesh.CommandFabric.help([])
    json(conn, 200, %{commands: help})
  end

  defp do_route(%Plug.Conn{request_path: path} = conn) do
    # Serve static dashboard or 404
    if path == "/" or path == "/dashboard" do
      serve_file(conn, 200, "priv/static/index.html")
    else
      json(conn, 404, %{error: "Not found"})
    end
  end

  defp dispatch_command(conn) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn),
         {:ok, params} <- Jason.decode(body) do
      command = params["command"]
      args = Mesh.CommandFabric.normalize_args(params["args"] || [])
      target = params["target"]

      result =
        if target do
          Mesh.CommandFabric.call(target_node(target), command, args)
        else
          Mesh.CommandFabric.broadcast(command, args)
        end

      _ =
        Mesh.Audit.record(%{
          "command" => command,
          "target" => target,
          "peer" => peer(conn),
          "denied" => match?({:error, {:not_allowlisted, _}}, result)
        })

      case result do
        {:error, {:not_allowlisted, cmd}} ->
          json(conn, 403, %{error: "not_allowlisted", command: cmd})

        {:error, reason} ->
          json(conn, 400, %{error: inspect(reason)})

        other ->
          json(conn, 200, %{result: format_rpc(other)})
      end
    else
      _ -> json(conn, 400, %{error: "Invalid request"})
    end
  end

  defp target_node(target) when is_binary(target) do
    String.to_existing_atom(target)
  rescue
    ArgumentError -> :unknown@node
  end

  defp target_node(target) when is_atom(target), do: target
  defp target_node(_), do: :unknown@node

  defp peer(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> nil
    end
  end

  defp json(conn, status, data) do
    conn
    |> Plug.Conn.put_status(status)
    |> Plug.Conn.send_resp(status, Jason.encode!(sanitize(data)))
  end

  defp format_rpc(list) when is_list(list) do
    Enum.map(list, fn
      {node, {:ok, result}} -> %{node: to_string(node), ok: true, result: result}
      {node, {:error, reason}} -> %{node: to_string(node), ok: false, error: inspect(reason)}
      {node, other} -> %{node: to_string(node), result: inspect(other)}
      other -> inspect(other)
    end)
  end

  defp format_rpc({:ok, result}), do: %{ok: true, result: result}
  defp format_rpc({:error, reason}), do: %{ok: false, error: inspect(reason)}
  defp format_rpc(other), do: inspect(other)

  defp sanitize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize(%MapSet{} = set), do: set |> MapSet.to_list() |> sanitize()
  defp sanitize(t) when is_tuple(t), do: t |> Tuple.to_list() |> sanitize()
  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)

  defp sanitize(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize_key(k), sanitize(v)} end)
  end

  defp sanitize(atom) when atom in [true, false, nil], do: atom
  defp sanitize(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp sanitize(other), do: other

  defp sanitize_key(k) when is_atom(k), do: Atom.to_string(k)
  defp sanitize_key(k) when is_binary(k), do: k
  defp sanitize_key(k), do: inspect(k)

  defp serve_file(conn, status, path) do
    case File.read(path) do
      {:ok, content} ->
        conn
        |> put_resp_header("content-type", "text/html")
        |> Plug.Conn.put_status(status)
        |> Plug.Conn.send_resp(status, content)

      {:error, _} ->
        json(conn, 404, %{error: "Not found"})
    end
  end
end
