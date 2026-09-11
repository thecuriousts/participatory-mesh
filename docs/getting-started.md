# Getting started

## Prerequisites

- Erlang/OTP 26+ / Elixir 1.15+ (see `mise.toml`)
- A private network between nodes (Tailscale is the dogfood path)
- Syncthing only if you want a live `~/sync` folder — not required to run CommandFabric

## Build a release

```bash
mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix release --overwrite
```

Copy `_build/prod/rel/mesh` to each node (or build per machine).

## Shared cookie

Generate once; use the same value on every node:

```bash
openssl rand -hex 16
```

## Start a node

```bash
export MESH_COOKIE="<shared-cookie>"
export MESH_NAME="mesh@$(tailscale ip -4)"   # or another stable private IP
./start_mesh.sh
```

Repeat on each machine with the same cookie.

## Verify

```bash
iex --name debug@$(tailscale ip -4) --cookie "$MESH_COOKIE" --remsh "$MESH_NAME"

Mesh.HealthMonitor.cluster_status()
Mesh.ServiceRegistry.all_services()
Mesh.CommandFabric.broadcast(:health_check)
```

Dashboard (when enabled): `http://<node-private-ip>:47989`

If both nodes answer `/health` but quorum stays **1/1**, see [Cluster troubleshooting](cluster-troubleshooting.md).

## Lab env

Copy `.env.lab.example` → `.env.lab` for local hostnames and IDs. That file is gitignored.
