defmodule Mesh.CommandFabric do
  @moduledoc """
  Distributed command execution fabric.
  Supports broadcast (fan-out), targeted cast, and request-response patterns.
  """
  use GenServer

  @default_timeout 30_000

  # Moat: mutate surface is this allowlist. `shell` is not here.
  # Unused lab adapters (syncthing/sunshine) and Helios paths (pull_git/deploy)
  # stay implemented but off the HTTP/RPC allowlist until a real job needs them.
  @allowed_commands ~w(health_check restart_service tailscale_status help)a

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{pending: %{}, results: %{}}}
  end

  # ============ Public API ============

  @doc """
  Broadcast command to all connected nodes (including local).
  Returns list of {node, result} tuples.
  """
  def broadcast(command, args \\ [], timeout \\ @default_timeout) do
    with {:ok, command} <- normalize_command(command) do
      nodes = [node() | Node.list()]

      {replies, _bad} =
        :rpc.multicall(nodes, __MODULE__, :execute_local, [command, args], timeout)

      Enum.zip(nodes, replies)
      |> Enum.map(fn
        {n, {:badrpc, reason}} -> {n, {:error, reason}}
        {n, result} -> {n, result}
      end)
    end
  end

  @doc """
  Cast command to specific node (fire-and-forget).
  """
  def cast(target_node, command, args \\ []) do
    case normalize_command(command) do
      {:ok, command} ->
        :rpc.cast(target_node, __MODULE__, :execute_local, [command, args])

      error ->
        error
    end
  end

  @doc """
  Execute command on specific node with response.
  """
  def call(target_node, command, args \\ [], timeout \\ @default_timeout) do
    with {:ok, command} <- normalize_command(command) do
      case :rpc.call(target_node, __MODULE__, :execute_local, [command, args], timeout) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
        {:badrpc, reason} -> {:error, reason}
        {:exit, reason} -> {:error, {:exit, reason}}
      end
    end
  end

  @doc """
  Execute command locally (called via RPC).
  """
  def execute_local(command, args) do
    with {:ok, command} <- normalize_command(command) do
      case apply(__MODULE__, command, [args]) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
        result -> {:ok, result}
      end
    end
  rescue
    e -> {:error, {:exception, __MODULE__, e}}
  end

  @doc """
  Normalize + hard-gate. opts: `:actor` (`:operator` | `:agent`), `:host`.
  Off-allowlist verbs only proceed for an operator under an active scoped bypass.
  """
  def authorize(command, opts \\ []) do
    actor = Keyword.get(opts, :actor, :agent)
    host = Keyword.get(opts, :host, Mesh.HardGate.hostname())

    case do_normalize(command) do
      {:ok, cmd} ->
        Mesh.HardGate.record_decision(:allow, %{
          command: to_string(cmd),
          actor: to_string(actor),
          host: host,
          bypass: "false"
        })

        {:ok, cmd}

      {:error, {:not_allowlisted, cmd}} = err ->
        if Mesh.HardGate.bypass_covers?(actor, cmd, host) do
          atom = coerce_command_atom(cmd)

          Mesh.HardGate.record_decision(:bypass, %{
            command: to_string(cmd),
            actor: "operator",
            host: host,
            bypass: "operator"
          })

          {:ok, atom}
        else
          Mesh.HardGate.record_decision(:deny, %{
            command: to_string(cmd),
            actor: to_string(actor),
            host: host,
            reason: "not_allowlisted"
          })

          err
        end
    end
  end

  defp normalize_command(command), do: authorize(command, [])

  defp do_normalize(command) when is_atom(command) do
    if command in @allowed_commands do
      {:ok, command}
    else
      {:error, {:not_allowlisted, command}}
    end
  end

  defp do_normalize(command) when is_binary(command) do
    allowed = Enum.map(@allowed_commands, &Atom.to_string/1)

    if command in allowed do
      {:ok, String.to_existing_atom(command)}
    else
      {:error, {:not_allowlisted, command}}
    end
  end

  defp do_normalize(command), do: {:error, {:not_allowlisted, command}}

  defp coerce_command_atom(cmd) when is_atom(cmd), do: cmd

  defp coerce_command_atom(cmd) when is_binary(cmd) do
    String.to_existing_atom(cmd)
  rescue
    ArgumentError -> String.to_atom(cmd)
  end

  # ============ Built-in Commands ============

  @doc """
  Health check on target node.
  """
  def health_check(_args) do
    {:ok,
     %{
       node: node(),
       memory: :erlang.memory([:total, :processes, :system]),
       uptime: :erlang.statistics(:wall_clock),
       timestamp: DateTime.utc_now()
     }}
  end

  @doc """
  Restart a systemd unit whose name is on MESH_ALLOWED_SERVICES or
  ~/.config/mesh/allowed_services. Empty allowlist → deny.
  """
  def restart_service(args) do
    service = arg(args, :service) || arg(args, 0)
    user = arg(args, :user) in [true, "true", "1"]

    cond do
      not is_binary(service) or service == "" ->
        {:error, :service_required}

      not service_name_safe?(service) ->
        {:error, :service_not_allowlisted}

      service not in allowed_services() ->
        {:error, :service_not_allowlisted}

      true ->
        cmd = if user, do: ["--user", "restart", service], else: ["restart", service]

        case System.cmd("systemctl", cmd) do
          {output, 0} -> {:ok, output}
          {output, code} -> {:error, {code, output}}
        end
    end
  end

  @doc """
  JSON/HTTP args → keyword list. Unknown keys dropped (no new atoms).
  """
  def normalize_args(args) when is_list(args) do
    if Keyword.keyword?(args), do: args, else: []
  end

  def normalize_args(args) when is_map(args) do
    Enum.flat_map(args, fn
      {k, v} when is_binary(k) ->
        case known_arg_key(k) do
          nil -> []
          atom -> [{atom, v}]
        end

      {k, v} when is_atom(k) ->
        [{k, v}]

      _ ->
        []
    end)
  end

  def normalize_args(_), do: []

  @doc """
  Pull git repository (dotfiles, etc).
  """
  def pull_git(args) do
    repo = Keyword.get(args, :repo) || Keyword.get(args, 0) || "~/dotfiles"
    branch = Keyword.get(args, :branch, "main")

    repo_path = Path.expand(repo)

    commands = [
      ["git", "-C", repo_path, "fetch", "origin"],
      ["git", "-C", repo_path, "reset", "--hard", "origin/#{branch}"],
      ["git", "-C", repo_path, "submodule", "update", "--init", "--recursive"]
    ]

    results =
      Enum.map(commands, fn cmd ->
        System.cmd(elem(cmd, 0), tl(cmd))
      end)

    if Enum.all?(results, fn {_out, code} -> code == 0 end) do
      {:ok, "Updated #{repo_path}"}
    else
      {:error, Enum.map(results, fn {out, code} -> {code, out} end)}
    end
  end

  @doc """
  Trigger Syncthing folder scan.
  """
  def trigger_syncthing_scan(args) do
    folder = Keyword.get(args, :folder)

    url = "http://localhost:8384/rest/db/scan"
    body = if folder, do: Jason.encode!(%{folder: folder}), else: "{}"

    case Req.post(url,
           body: body,
           headers: ["Content-Type": "application/json"],
           receive_timeout: 2_000,
           retry: false
         ) do
      {:ok, %{status: 200}} -> {:ok, "Scan triggered"}
      {:ok, %{status: code, body: body}} -> {:error, {code, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get Syncthing status.
  """
  def syncthing_status(_args) do
    case Req.get("http://localhost:8384/rest/system/status", receive_timeout: 500, retry: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, {code, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get Sunshine status.
  """
  def sunshine_status(_args) do
    case Req.get("https://localhost:47990/api/status",
           receive_timeout: 500,
           retry: false,
           connect_options: [transport_opts: [verify: :verify_none]]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, {code, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get Tailscale status.
  """
  def tailscale_status(_args) do
    case System.cmd("tailscale", ["status", "--json"]) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, :parse_failed}
        end

      {_output, code} ->
        {:error, code}
    end
  end

  @doc """
  Arbitrary shell — off the allowlist. Only if MESH_ALLOW_SHELL=1 (not dogfood).
  """
  def shell(_args) do
    {:error, :shell_disabled}
  end

  def peer_up(peer), do: {:ok, {:peer_up, peer}}
  def peer_down(peer), do: {:ok, {:peer_down, peer}}
  def split_brain(peers), do: {:ok, {:split_brain, peers}}
  def resolve_syncthing_conflict(_args), do: {:error, :not_implemented}

  @doc """
  Deploy/update this mesh application.
  """
  def deploy(args) do
    version = Keyword.get(args, :version)
    repo = Keyword.get(args, :repo, "~/mesh")

    commands = [
      ["git", "-C", Path.expand(repo), "fetch", "origin"],
      ["git", "-C", Path.expand(repo), "checkout", version || "main"],
      ["mix", "deps.get"],
      ["mix", "compile"],
      ["mix", "release", "--overwrite"]
    ]

    results =
      Enum.map(commands, fn [cmd | args] ->
        System.cmd(cmd, args, timeout: 120_000)
      end)

    if Enum.all?(results, fn {_out, code} -> code == 0 end) do
      # Restart the node
      spawn(fn ->
        :timer.sleep(1000)
        System.cmd("systemctl", ["--user", "restart", "mesh"])
      end)

      {:ok, "Deployed and restarting"}
    else
      {:error, results}
    end
  end

  @doc """
  List available commands.
  """
  def help(_args) do
    {:ok,
     [
       "health_check: this node",
       "tailscale_status: tailscale status --json",
       "restart_service: named unit on the service allowlist only",
       "help: this list"
     ]}
  end

  defp arg(args, key) when is_list(args) and is_atom(key) do
    if Keyword.keyword?(args), do: Keyword.get(args, key)
  end

  defp arg(args, key) when is_list(args) and is_integer(key) do
    Enum.at(args, key)
  end

  defp arg(_, _), do: nil

  defp known_arg_key("service"), do: :service
  defp known_arg_key("user"), do: :user
  defp known_arg_key("repo"), do: :repo
  defp known_arg_key("branch"), do: :branch
  defp known_arg_key("folder"), do: :folder
  defp known_arg_key("version"), do: :version
  defp known_arg_key(_), do: nil

  defp service_name_safe?(name) do
    Regex.match?(~r/\A[A-Za-z0-9@._-]+\z/, name)
  end

  defp allowed_services do
    env =
      System.get_env("MESH_ALLOWED_SERVICES", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    file =
      case File.read(Path.expand("~/.config/mesh/allowed_services")) do
        {:ok, body} ->
          body
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

        _ ->
          []
      end

    Enum.uniq(env ++ file)
  end
end
