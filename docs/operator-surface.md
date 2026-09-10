# Operator surface

## Allowlisted commands

Current verbs bots and harnesses may dispatch (dogfood):

| Command | Args | Description |
|---------|------|-------------|
| `health_check` | — | Node health (load, mem, disk) |
| `restart_service` | `service`, `user?` | Restart a **service-allowlisted** unit only |
| `tailscale_status` | — | Tailscale peers / status |
| `help` | — | List allowlisted commands |

`shell` is implemented but **not** on the allowlist. Other verbs may exist in the codebase and stay off HTTP/RPC until a real job needs them.

## HTTP examples

Replace the host with a node private IP:

```bash
curl -X POST http://NODE:47989/command \
  -H "Content-Type: application/json" \
  -d '{"command":"health_check"}'

curl http://NODE:47989/health
curl http://NODE:47989/services
```

Denied commands return `403` with `not_allowlisted`.

## CLI

`bin/mesh` talks to CommandFabric with a bearer token. Prefer it when you want to **dispatch** an allowlisted act without opening SSH.

## systemd (optional)

```bash
sudo cp mesh.service /etc/systemd/system/mesh@.service
sudo mkdir -p /etc/mesh
# put MESH_COOKIE and private IP into /etc/mesh/<instance>.env
sudo systemctl daemon-reload
sudo systemctl enable --now mesh@$(whoami)
```

## Config sketch

```elixir
Mesh.ConfigStore.put("syncthing/folders", %{
  "projects" => %{path: "~/projects", priority: 1}
})

Mesh.ConfigStore.get("syncthing/folders")
```
