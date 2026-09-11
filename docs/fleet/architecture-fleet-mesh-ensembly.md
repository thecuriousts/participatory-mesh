# Fleet architecture: mesh, ensembly, and HITL (2026-09)

Durable reference for the **linux-node + mac-node** fleet slice and how it connects to the Grok Bot computer. Operational day log: [2026-09-12-mini-linux-node-bringup.md](2026-09-12-mini-linux-node-bringup.md).

**Trust boundary unchanged:** bots reach homelab only through **CommandFabric** allowlist on `:47989`. See [../architecture.md](../architecture.md).

**Addresses stay local:** Tailscale IPs, `.local` hostnames, and device IDs belong in `.env.lab` (from [`.env.lab.example`](../../.env.lab.example)) and `~/.config/mesh/nodes` — not in committed markdown.

---

## Host summary

| Label | Erlang node | Primary roles |
|-------|-------------|---------------|
| **linux-node** | `mesh@<tailscale-ipv4>` | Mesh node, RustDesk rendezvous/relay, Omarchy mesh-bar, Steward WHERE card |
| **mac-node** | `mesh@<tailscale-ipv4>` | Mesh node, ensembly **import client**, RustDesk host, SwiftBar ensembly menu |
| **ensemble-ops-writer** | — | Ensembly **ops writer**, Grok Build worktrees, HOOTL dispatch to mesh |

Resolve `<tailscale-ipv4>` per host from `MESH_TS_A` / `MESH_TS_B` in `.env.lab`.  
Cookie path (all mesh nodes): `~/.config/mesh/cookie`  
Peer list (join helper): `~/.config/mesh/nodes`

---

## 1. Fleet topology

Tailscale is the only routable fabric between cloud Bot, Linux laptop, and headless Mac.

```mermaid
flowchart TB
  subgraph cloud["ensemble-ops-writer (xAI cloud)"]
    GB[Grok Bot / Grok Build]
    EW[(ensembly ops SQLite<br/>canonical writer)]
    GB --> EW
  end

  subgraph tailnet["Tailscale tailnet"]
    subgraph mz["linux-node"]
      MZ_MESH["mesh@&lt;tailscale-ipv4&gt;<br/>:47989 CommandFabric"]
      MZ_RD["RustDesk hbbs/hbbr<br/>:21116"]
      MZ_BAR[Omarchy mesh-bar]
      MZ_WHERE[fleet-where.md<br/>Steward]
    end

    subgraph mini["mac-node"]
      MN_MESH["mesh@&lt;tailscale-ipv4&gt;<br/>:47989 CommandFabric"]
      MN_ENS[ensembly import client<br/>pulse-memory]
      MN_RD[RustDesk host]
      MN_SW[SwiftBar ensembly.30s]
    end
  end

  GB -->|"HOOTL :47989 /command"| MZ_MESH
  GB -->|"HOOTL :47989 /command"| MN_MESH
  EW -.->|"pulse import (read path)"| MN_ENS

  MZ_MESH <-->|"Erlang dist 9100-9200"| MN_MESH
  MZ_RD <-->|"HITL desktop"| MN_RD

  FD[Fleet Desk<br/>orchestration] -.->|"HOOTL policy"| GB
  FD -.->|"links only"| MZ_WHERE
  OP[Human operator] -->|"HITL RustDesk"| MN_RD
```

**Legend**

- **Solid lines:** runtime data / control paths in production
- **Dotted lines:** policy, import, or human-only paths
- **Parked:** native macOS Screen Sharing / VNC (not shown)

---

## 2. Mesh OTP cluster

Two-node distributed Erlang over Tailscale. Both nodes use **longnames** = `mesh@<tailscale-ipv4>`.

```mermaid
flowchart LR
  subgraph linux-node["linux-node"]
    EPMD1[EPMD :4369]
    HTTP1[WebServer :47989]
    HM1[HealthMonitor]
    CF1[CommandFabric]
    EPMD1 --- BEAM1["BEAM mesh@&lt;tailscale-ipv4&gt;<br/>dist 9100-9200"]
    BEAM1 --> HTTP1 & HM1 & CF1
  end

  subgraph mini["mac-node"]
    EPMD2[EPMD :4369]
    HTTP2[WebServer :47989]
    HM2[HealthMonitor]
    CF2[CommandFabric]
    LA[mesh-join-peers.sh<br/>every 120s]
    EPMD2 --- BEAM2["BEAM mesh@&lt;tailscale-ipv4&gt;<br/>dist 9100-9200"]
    BEAM2 --> HTTP2 & HM2 & CF2
    LA -->|"Node.connect peers<br/>from ~/.config/mesh/nodes"| BEAM2
  end

  BEAM1 <-->|"inet_tcp dist"| BEAM2

  subgraph firewall["linux-node ufw tailscale0"]
    P1[47989/tcp]
    P2[4369/tcp]
    P3[9100-9200/tcp]
  end

  firewall -.->|"must allow mac-node → linux-node"| BEAM1
```

### Port matrix

| Port | Protocol | Purpose |
|------|----------|---------|
| 47989 | TCP | HTTP health, dashboard, `/command` |
| 4369 | TCP | EPMD (Erlang Port Mapper Daemon) |
| 9100–9200 | TCP | Erlang distribution (pinned via `ELIXIR_ERL_OPTIONS`) |
| 21116 | TCP | RustDesk rendezvous (hbbs; typical default) |

### Peer discovery model

`Mesh.HealthMonitor` tracks peers from `[node() | Node.list()]`. It does **not** read `~/.config/mesh/nodes` itself. The mac-node LaunchAgent `mesh-join-peers.sh` closes the gap by calling `Node.connect/1` on boot and every 120 seconds.

### Quorum

With two nodes, healthy cluster means:

- `quorum.up == 2`, `quorum.total == 2`, `has_quorum == true`
- `split_brain == false`
- Peer keys in `/health` JSON are longnames (`mesh@<tailscale-ipv4>`), not hostnames or `.local` names

### Tailscale note

linux-node **ShieldsUp=false** is required in addition to ufw. ShieldsUp blocks Tailscale inbound even when local firewall allows traffic.

---

## 3. Ensembly: write path vs mac-node import

Single writer for ops SQLite; mac-node is import-only.

```mermaid
sequenceDiagram
  participant Bot as ensemble-ops-writer
  participant Ops as ensembly ops DB (writer)
  participant Pulse as pulse / export channel
  participant Mini as mac-node ensembly client
  participant Mesh as mesh CommandFabric

  Bot->>Ops: authorize / claim / mutate (canonical)
  Bot->>Mesh: HOOTL dispatch allowlisted verb
  Mesh->>Mini: :rpc peer execute (if target is mac-node)

  Ops-->>Pulse: published ops / pulse feed
  Pulse-->>Mini: import client sync (read)
  Note over Mini,Ops: No dual-write from mac-node to ops DB

  Mini->>Mesh: ensembly_status / ensembly_channel_ir (read-only allowlist)
```

| Concern | Owner |
|---------|-------|
| done / pending / denied ledger | ensembly on ensemble-ops-writer |
| Allowlisted machine acts on homelab | mesh CommandFabric |
| mac-node local aux / pulse-memory | mac-node import client |
| **Refused** | Dual-writing ops SQLite from mesh nodes |

Cross-participant pattern (unchanged from product map):

```
bot proposes → ensembly authorizes/claims → CommandFabric dispatches → peer executes
```

See [../../arch-design/ensembly-bridge.md](../../arch-design/ensembly-bridge.md).

---

## 4. HOOTL vs HITL control planes

Two orthogonal surfaces: automation (HOOTL) and human GUI (HITL).

```mermaid
flowchart TB
  subgraph hootl["HOOTL — hands-off operator loop"]
    FD[Fleet Desk]
    GB[Grok Bot]
    API["mesh :47989<br/>/health /command"]
    CLI[bin/mesh CLI]
    ENS[ensembly authorize → claim]

    FD --> GB
    GB --> ENS
    GB --> API
    FD --> CLI
    CLI --> API
    API --> CF[CommandFabric allowlist]
  end

  subgraph hitl["HITL — human GUI control"]
    OP[Operator]
    RD_C[RustDesk client on linux-node]
    RD_S[RustDesk host on mac-node]
    MAC[macOS System Settings<br/>Accessibility + Screen Recording]

    OP --> RD_C
    RD_C -->|"via hbbs on linux-node :21116"| RD_S
    RD_S --> MAC
  end

  CF -->|"restart_service, health_check, …"| MINI[mac-node OS / services]

  note1[Parked: native VNC / Screen Sharing]
  style note1 fill:#f9f,stroke:#999,stroke-dasharray: 5 5
```

| Mode | Actor | When |
|------|-------|------|
| HOOTL | Grok Bot + Fleet Desk | Routine fleet ops, allowlisted mesh verbs, ensembly lifecycle |
| HITL | Human operator via RustDesk | Password prompts, TCC dialogs, menu bar, SwiftBar/Control Center |

**Supporting infra:** `caffeinate -dims` LaunchAgent keeps mac-node awake during remote sessions.

**RustDesk gotcha:** `collapse_toolbar=Y` can hide the view-only toggle even when `view_only=false` in config — verify toolbar state before debugging input issues.

---

## 5. Fleet roles

```mermaid
flowchart LR
  FD[Fleet Desk]
  ST[Steward]
  COS[CoS / plate-token]

  FD -->|"HOOTL orchestration"| MESH[mesh + ensembly flow]
  FD -.->|"link only"| WHERE["~/.local/share/fleet-where.md<br/>on linux-node"]
  ST -->|"owns"| WHERE
  ST -->|"infra"| MZ[linux-node machine]
  ST -->|"infra"| MINI[mac-node machine]
  COS -.->|"credentials policy"| FD

  FD -.-x|"does not own"| MZ
  FD -.-x|"does not own"| GB_INFRA[ensemble-ops-writer infra]
```

---

## 6. Component map (mesh OTP)

Same modules as generic mesh; fleet adds join helpers and pinned dist ports.

| Module | Fleet-relevant behavior |
|--------|-------------------------|
| **CommandFabric** | Allowlisted RPC; Grok Bot primary remote control |
| **HealthMonitor** | Quorum 2/2; peers from `Node.list()` |
| **WebServer** | `:47989` on each node |
| **ConfigStore** | In-memory merge across connected nodes |
| **TailscaleWatcher** | Peer up/down events when CLI present |
| **ServiceRegistry** | Local service map per node |

---

## 7. Security posture (summary)

| Layer | linux-node | mac-node |
|-------|--------|----------|
| Mesh auth | Shared cookie file; bearer token for CLI | Same cookie; LaunchAgent env |
| Network | ufw on `tailscale0`; ShieldsUp off | Hardening script; Tailscale only |
| Remote GUI | RustDesk client | RustDesk host + macOS TCC |
| Remote shell | Not primary control plane | Remote Login off (policy) |
| Secrets in git | **Never** — use local paths only | **Never** |

---

## Related docs

- [2026-09-12-mini-linux-node-bringup.md](2026-09-12-mini-linux-node-bringup.md) — day log and verification commands
- [../architecture.md](../architecture.md) — CommandFabric trust boundary
- [../operator-surface.md](../operator-surface.md) — HTTP/CLI operator surface
- [../getting-started.md](../getting-started.md) — build and start (generic)
- [../../arch-design/ensembly-bridge.md](../../arch-design/ensembly-bridge.md) — product ownership boundaries
- [../../.env.lab.example](../../.env.lab.example) — local labels and IP placeholders
