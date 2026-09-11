import Config

cookie =
  System.get_env("MESH_COOKIE") ||
    case File.read(Path.expand("~/.config/mesh/cookie")) do
      {:ok, t} -> String.trim(t)
      _ -> nil
    end ||
    case config_env() do
      :prod -> raise "MESH_COOKIE env var or ~/.config/mesh/cookie required"
      _ -> "dev-cookie"
    end

# Runtime configuration for releases
config :mesh, :cluster,
  cookie: cookie,
  name: System.get_env("MESH_NAME") || "mesh@#{System.get_env("TAILSCALE_IP") || "localhost"}"

config :mesh, :tailscale,
  api_key: System.get_env("TAILSCALE_API_KEY"),
  poll_interval: 15_000

config :mesh, :syncthing,
  api_key: System.get_env("SYNCTHING_API_KEY"),
  base_url: "http://localhost:8384"

config :mesh, :sunshine,
  base_url: "https://localhost:47990",
  verify_ssl: false

web_port =
  case System.get_env("MESH_WEB_PORT") do
    n when is_binary(n) and n != "" ->
      String.to_integer(n)

    _ ->
      case config_env() do
        :test -> 47_991
        _ -> 47_989
      end
  end

config :mesh, :web_server,
  port: web_port,
  dashboard_enabled: System.get_env("MESH_DASHBOARD") != "false"

# Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:node, :request_id]
