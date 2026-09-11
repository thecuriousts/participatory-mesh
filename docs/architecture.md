# Architecture overview

## Trust boundary

Untrusted bots and harnesses reach the mesh only through **CommandFabric**. If a verb is not on the allowlist, it is denied. That is the product.

```
Bots / harnesses / operators
        │
        ▼
┌───────────────────┐
│  HTTP / CLI / RPC │
└─────────┬─────────┘
          ▼
┌───────────────────┐
│  CommandFabric    │  ← allowlist (only these verbs dispatch)
└─────────┬─────────┘
          ▼
┌───────────────────┐     ┌─────────────────┐
│ ServiceRegistry   │     │ ConfigStore     │
│ HealthMonitor     │     │ SyncCoordinator │
│ TailscaleWatcher  │     │ (optional)      │
└───────────────────┘     └─────────────────┘
          │
          ▼
   Distributed Erlang nodes on a private network
```

## Core pieces

| Module | Job |
|--------|-----|
| **CommandFabric** | Allowlisted commands only; `shell` never ships on the allowlist |
| **ServiceRegistry** | Local map of services the node knows about |
| **ConfigStore** | Shared config with merge semantics across nodes |
| **HealthMonitor** | Cluster health / partition awareness |
| **SyncCoordinator** | Optional Syncthing conflict helpers |
| **TailscaleWatcher** | Peer events when Tailscale CLI is present |
| **Web server** | Dashboard + JSON command API on `:47989` |

## What this is not

- Not a general remote shell
- Not a multi-tenant cloud control plane
- Not a requirement to run Sunshine or share the mesh checkout over Syncthing

## With ensembly (cross-participant)

This mesh **dispatches** allowlisted machine acts. It does not own life-state ledgers.

An operator kernel ([ensembly](https://github.com/thecuriousts/ensembly)) can **authorize and claim** work on one node and still get an allowlisted act **done on another participant** through CommandFabric:

**bot/harness proposes → ensembly authorizes/claims → mesh dispatches → peer node executes.**

Ensembly owns whether the act is owed. Mesh owns that only allowlisted verbs run across the Tailscale cluster. Syncthing, Sunshine, and VNC are optional host tools — they do not decide what bots may run.

## Fleet topology (2026-09)

Two-node fleet slice (**linux-node** + **mac-node**) over Tailscale: mesh OTP cluster, ensembly import on mac-node, ensemble-ops-writer as ensembly ops writer, RustDesk for headless HITL. Public docs describe **roles and ports only** — operator-specific pairing (Tailscale IPs, `.local` hostnames, device IDs) stays in local [`.env.lab`](../.env.lab.example) and `~/.config/mesh/nodes`, not in git.

| Doc | Contents |
|-----|----------|
| [Fleet bring-up log (2026-09-12)](fleet/2026-09-12-mini-linux-node-bringup.md) | Day log, fixes (longnames, ShieldsUp, ufw, dist ports), verification |
| [Fleet architecture](fleet/architecture-fleet-mesh-ensembly.md) | Mermaid topology: mesh cluster, ensembly import, HOOTL/HITL |

Generic build/start remains in [getting-started.md](getting-started.md). Cookies and tokens stay under `~/.config/mesh/` — never committed.
