# participatory-mesh

An on-prem **CommandFabric** for a small private mesh (Tailscale): untrusted bots and harnesses may only **dispatch allowlisted commands**. The product is the **allowlist**, not chat.

Arbitrary shell stays off the allowlist.

## What you get

| Piece | Role |
|-------|------|
| **CommandFabric** | Decides which verbs bots/harnesses may run — and runs only those |
| **OTP cluster** | Erlang/Elixir nodes coordinating over a private network |
| **Operator CLI** | `bin/mesh` with a bearer token — dispatch without opening SSH |
| **Optional Syncthing** | Live folder sync (`~/sync`) — not required to run the cluster |

## With an operator kernel

Pair with [ensembly](https://github.com/thecuriousts/ensembly) when you want durable **done / pending / denied** above CommandFabric: a bot or harness can **authorize and claim** on one node, then **dispatch** an allowlisted act onto another participant. See [docs/architecture.md](docs/architecture.md).

## Hard allow

Deny-by-default CommandFabric allowlist with **audit always** and an **operator-only TTL bypass**. Agents cannot disable HardAllow. See [Operator surface](docs/operator-surface.md#hard-allow-p3-v0).

## Docs

| Doc | Contents |
|-----|----------|
| [Getting started](docs/getting-started.md) | Build, cookie, start, verify |
| [Cluster troubleshooting](docs/cluster-troubleshooting.md) | Two-node quorum 1/1 when `/health` works |
| [Architecture overview](docs/architecture.md) | Components and trust boundary |
| [Operator surface](docs/operator-surface.md) | Allowlisted commands, HTTP API, systemd |
| [Fleet bring-up (2026-09)](docs/fleet/2026-09-12-mini-linux-node-bringup.md) | mac-node + linux-node mesh/ensembly/RustDesk ops log |
| [Fleet architecture](docs/fleet/architecture-fleet-mesh-ensembly.md) | Topology diagrams (mesh, ensembly, HITL) |

Hostnames, Tailscale IPs, and device IDs stay out of git — use a local `.env.lab` from `.env.lab.example`.

## License

MIT
