# Fleet bring-up log: mac-node + linux-node (2026-09-11/12)

Operator day log for the two-node mesh cluster, ensembly import on mac-node, and RustDesk HITL path. Durable architecture diagrams live in [architecture-fleet-mesh-ensembly.md](architecture-fleet-mesh-ensembly.md).

**Audience:** Fleet Desk, Steward, Grok Bot operators. No secrets in this doc — refer to paths like `~/.config/mesh/cookie`, not values.

**Host-specific IPs and hostnames:** copy [`.env.lab.example`](../../.env.lab.example) → `.env.lab` (gitignored) and fill `MESH_TS_*`. Peer longnames go in `~/.config/mesh/nodes`. Never commit live Tailscale addresses or `.local` names to git.

---

## Scope

| In scope | Parked / out of scope |
|----------|----------------------|
| linux-node ↔ mac-node mesh OTP cluster (2/2 quorum) | Third omarchy node (not joined this sprint) |
| Ensembly **import client** on mac-node | Dual-write ops SQLite from mac-node |
| RustDesk HITL for headless mac-node GUI | Native macOS Screen Sharing / VNC |
| Grok Bot computer as ensembly **ops writer** | Grok software on homelab hosts |

---

## Hosts (2026-09-12 end state)

Use labels below in docs and fleet maps. Resolve addresses from `.env.lab` on the operator machine.

| Label | Erlang node (longname) | Mesh runtime | Notes |
|-------|------------------------|--------------|-------|
| **linux-node** (Linux laptop) | `mesh@<tailscale-ipv4>` | systemd user `mesh.service` (`mix run --name mesh@$IP`) | Omarchy mesh-bar via `bin/mesh-bar` / omarchy plugin |
| **mac-node** (headless Mac) | `mesh@<tailscale-ipv4>` | prod release under `~/dev/products/mesh` | LaunchAgents (see below) |
| **ensemble-ops-writer** (xAI cloud) | — | ensembly ops writer only | Reaches mesh via `:47989` / CommandFabric over Tailscale |

Example `.env.lab` keys (see [`.env.lab.example`](../../.env.lab.example)):

```bash
MESH_HOST_A=linux-node
MESH_HOST_B=mac-node
MESH_TS_A=          # fill locally
MESH_TS_B=          # fill locally
```

### mac-node LaunchAgents

| Label | Script / command | Interval |
|-------|------------------|----------|
| `ai.kingsparrow.mesh` | `~/bin/mesh-autostart.sh` | on login / keepalive |
| `ai.kingsparrow.mesh-join` | `~/bin/mesh-join-peers.sh` | every **120s** |
| `ai.kingsparrow.caffeinate` | `/usr/bin/caffeinate -dims` | continuous (keeps mac-node awake for remote desktop) |

### Isomorphic dev tree (mac-node)

mac-node mirrors the standard Kingsparrow layout under `~/dev/`:

```
~/dev/
├── agentic-reactor/
├── cultural-creative/
├── foundations-infra/
├── presence-career/
├── products/          ← mesh release lives here
├── research-prototypes/
└── ensembly/          ← import client build (not ops writer)
```

---

## What broke and what fixed it

Bring-up spanned **2026-09-11 → 2026-09-12**. Each item below was a blocker until resolved.

### 1. Short Erlang node name on mac-node

**Symptom:** mac-node registered as `mesh@<hostname>` (sname) while linux-node used longname `mesh@<tailscale-ipv4>`. Distribution handshake failed across hosts.

**Fix:** mac-node release must use longnames tied to Tailscale IP:

```bash
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE="mesh@$(tailscale ip -4)"
# → mesh@<tailscale-ipv4>  (see MESH_TS_B in .env.lab)
```

Do **not** use hostname-based sname or `.local` names for cross-host clustering.

### 2. Tailscale ShieldsUp on linux-node

**Symptom:** mac-node could not reach linux-node even when `ufw` appeared open on `tailscale0`.

**Cause:** Tailscale **ShieldsUp=true** on linux-node blocked inbound Tailscale traffic regardless of local firewall rules.

**Fix:** Steward set `shields-up=false` on linux-node (Tailscale admin or `tailscale set --shields-up=false` on the host).

### 3. ufw on linux-node (tailscale0)

**Symptom:** EPMD / dist / HTTP timeouts from mac-node.

**Fix:** Allow on `tailscale0` (Tailscale CGNAT range):

| Port(s) | Service |
|---------|---------|
| `47989/tcp` | Mesh HTTP / CommandFabric |
| `4369/tcp` | EPMD |
| `9100:9200/tcp` | Erlang distribution (pinned range) |

Example (operator adjusts interface name if needed):

```bash
sudo ufw allow in on tailscale0 to any port 47989 proto tcp
sudo ufw allow in on tailscale0 to any port 4369 proto tcp
sudo ufw allow in on tailscale0 to any port 9100:9200 proto tcp
```

### 4. Ephemeral Erlang dist port

**Symptom:** mac-node bound dist on an ephemeral port (e.g. `:59017`). ufw rule for `9100:9200` did not match; connect succeeded intermittently or not at all.

**Fix:** Pin dist listen range on **both** hosts:

```bash
export ELIXIR_ERL_OPTIONS='-kernel inet_dist_listen_min 9100 -kernel inet_dist_listen_max 9200'
```

Set in mac-node LaunchAgent env, linux-node systemd user unit, or shell profile. Repo release defaults in `config/vm.args.eex` use `9000–9010`; fleet operators standardized on **9100–9200** to match live ufw rules.

### 5. HealthMonitor peers only from `Node.list()`

**Symptom:** After boot, `/health` showed one node or stale peer set until manual connect.

**Cause:** `Mesh.HealthMonitor` seeds peers from `[node() | Node.list()]` at init; it does not auto-discover peers from config alone.

**Fix:** `~/bin/mesh-join-peers.sh` (mac-node, every 120s) reads `~/.config/mesh/nodes` and runs `Node.connect/1` for each peer longname. Ensure that file lists both nodes (IPs from `.env.lab`), e.g.:

```
mesh@<MESH_TS_A>
mesh@<MESH_TS_B>
```

(Same cookie on both hosts — stored at `~/.config/mesh/cookie`, never committed.)

---

## Healthy end state (verification)

Load lab env, then probe both nodes:

```bash
set -a && . ./.env.lab && set +a

curl -s "http://${MESH_TS_A}:47989/health" | jq .
curl -s "http://${MESH_TS_B}:47989/health" | jq .
```

Expected shape:

- `quorum`: `{ "total": 2, "up": 2, "has_quorum": true }` → **2/2**
- `peers`: both entries are **longnames** (`mesh@<tailscale-ipv4>`), not hostnames or `.local` names
- `split_brain`: `false`

Remote console check (cookie from `~/.config/mesh/cookie`):

```bash
iex --name debug@$(tailscale ip -4) --cookie "$(cat ~/.config/mesh/cookie)" \
  --remsh "mesh@$(tailscale ip -4)"

Node.list()
# => peer longname(s) only, e.g. [:"mesh@<tailscale-ipv4>"]

Mesh.HealthMonitor.cluster_status()
```

---

## Ensembly on mac-node (import client)

| Role | Host label |
|------|------------|
| **Ops SQLite writer** (canonical) | ensemble-ops-writer |
| **Pulse import client** | mac-node |

Steps performed during bring-up:

1. Clone/build ensembly under `~/dev/products/ensembly` on mac-node (isomorphic to other `~/dev` repos).
2. Configure **pulse import** — mac-node pulls/consumes; does **not** dual-write ops DB (see [arch-design/ensembly-bridge.md](../../arch-design/ensembly-bridge.md): "Refuse dual-writing ensembly ops SQLite from mesh nodes").
3. Seed **pulse-memory** on mac-node for local read/aux state.
4. Install SwiftBar plugin `ensembly.30s.sh` for menu-bar status (may require unhiding via Control Center / Ice if the icon is collapsed).

Read-only mesh verbs (already on allowlist): `ensembly_status`, `ensembly_channel_ir` via CommandFabric.

---

## Desktop sharing: RustDesk HITL

Native **Screen Sharing / VNC is parked.** Headless mac-node GUI work uses **RustDesk**.

| Component | Location |
|-----------|----------|
| Self-hosted rendezvous + relay | linux-node (`:${RUSTDESK_HBBS_PORT:-21116}` — set in local env) |
| mac-node RustDesk host | `enable-keyboard=Y`, `access-mode=full` |
| Keep-awake | `caffeinate -dims` LaunchAgent |

Point RustDesk clients at the rendezvous host IP from `MESH_TS_A` in `.env.lab`.

### HOOTL vs HITL

| Mode | Who drives | Surface |
|------|------------|---------|
| **HOOTL** (hands-off operator loop) | Grok Bot via Fleet Desk / CommandFabric / CLI | `:47989`, `bin/mesh`, ensembly authorize→dispatch |
| **HITL** (human in the loop) | Operator takes GUI control | RustDesk session to mac-node |

Typical flow: Grok Bot drives HOOTL automation; operator watches; operator grabs RustDesk for password sheets, System Settings, menu bar, or Accessibility prompts.

### Gotchas

1. **Collapsed toolbar:** linux-node peer may show `view_only=false` while RustDesk toolbar is collapsed (`collapse_toolbar=Y`) — the View-mode toggle is hidden. Expand toolbar or fix config before assuming view-only is off.
2. **macOS permissions:** RustDesk needs **Accessibility** and **Screen Recording** for remote clicks on mac-node. Grant via System Settings (HITL) or MDM/profile if available.
3. **CLI over GUI:** Prefer `sudo` / CLI for headless ops instead of invisible GUI password sheets.

---

## Security hardening (mac-node)

A mesh-repo hardening script (under `scripts/` on mac-node checkout) was applied during bring-up:

- Host firewall tightened while preserving Tailscale, mesh ports, and RustDesk
- SMB guest access disabled
- Remote Login (SSH) disabled where policy allows — Tailscale + mesh API remain the control plane

Re-run after OS updates if settings drift. Details stay in the script comments on mac-node; this doc does not duplicate vendor-specific steps.

---

## Roles: Fleet Desk vs Steward

| Role | Owns | Does not own |
|------|------|--------------|
| **Fleet Desk** | Ensembly-aware fleet map; HOOTL start/stop/reroute; mesh/ensembly **orchestration** docs | linux-node / ensemble-ops-writer infra; plate/token (CoS) |
| **Steward** | Machine infra; **WHERE** card on linux-node (`~/.local/share/fleet-where.md`) | Fleet Desk routing policy |

Fleet Desk links to Steward WHERE cards; it does not edit them.

---

## Operator quick reference

### Restart mesh on linux-node (systemd user)

```bash
systemctl --user restart mesh.service
systemctl --user status mesh.service
journalctl --user -u mesh.service -f
```

### Restart mesh on mac-node

```bash
~/bin/mesh-autostart.sh   # or reload LaunchAgent
tail -f ~/Library/Logs/mesh/mesh.log   # path may vary per install
```

### Force peer join (mac-node)

```bash
~/bin/mesh-join-peers.sh
```

### Tailscale shields check (linux-node)

```bash
tailscale debug prefs | jq '.ShieldsUp'
# should be false for mesh peers to connect inbound
```

---

## Related docs

- [architecture-fleet-mesh-ensembly.md](architecture-fleet-mesh-ensembly.md) — diagrams and durable topology
- [../architecture.md](../architecture.md) — CommandFabric trust boundary + fleet link
- [../../arch-design/ensembly-bridge.md](../../arch-design/ensembly-bridge.md) — ensembly × mesh ownership
- [../getting-started.md](../getting-started.md) — generic build/cookie/start
- [../operator-surface.md](../operator-surface.md) — allowlisted verbs and HTTP API
- [../../.env.lab.example](../../.env.lab.example) — local host labels and IP placeholders

---

## Changelog

| Date | Event |
|------|-------|
| 2026-09-11 | mac-node mesh release + longname fix started |
| 2026-09-11 | ShieldsUp + ufw + dist port pin resolved |
| 2026-09-12 | 2/2 quorum verified; ensembly import + RustDesk HITL online |
