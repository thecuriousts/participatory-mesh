# Multi-node cluster troubleshooting (Tailscale)

Two mesh nodes can each answer HTTP on `:47989` while Erlang clustering stays at **quorum 1/1** — only `self` in peers, no remote peer. HTTP health and OTP distribution are separate paths. Work through this list in order.

## Quick checklist

| Step | Check | Pass |
|------|-------|------|
| 1 | Longname on every node | `/health` → `"self": "mesh@<ts-ip>"` (Tailscale IPv4, not hostname) |
| 2 | Cookie bytes match | `sha256sum ~/.config/mesh/cookie` identical on every node |
| 3 | Peers listed | `~/.config/mesh/nodes` has each peer Tailscale IPv4 (one per line) |
| 4 | HTTP both ways | `curl http://<peer-ts-ip>:47989/health` works from **each** node to the other |
| 5 | Host firewall | `ufw` (or equivalent) allows `tailscale0` inbound: TCP `47989`, `4369`, `9000:9010` |
| 6 | Tailscale Shields Up | `tailscale debug prefs` → `ShieldsUp: false` on nodes that must accept peers |
| 7 | Erlang join from **live** mesh | `Node.connect/1` via `--remsh` to the running node — not a throwaway `debug@…` shell |
| 8 | Quorum | Both `/health` show `quorum.total=2`, `quorum.up=2`, both longname peers, `split_brain=false` |

```bash
bin/mesh status    # GET /health on every line in ~/.config/mesh/nodes
```

---

## Symptom: quorum 1/1, peers only show self

Both nodes return JSON from `/health`, but each reports something like:

```json
"quorum": {"total": 1, "up": 1, "has_quorum": true},
"peers": {"mesh@<ts-ip-a>": {"status": "up", ...}}
```

The other node's longname never appears. Fix the items below before expecting `2/2`.

---

## 1. Longname vs shortname

OTP nodes must use a **long distribution name** with the Tailscale IPv4:

```
mesh@<tailscale-ipv4>
```

Shortnames like `mesh@Hostname` or `mesh@laptop-1` **cannot** join peers that use `mesh@100.x.x.x`. Mixed naming is the most common silent failure.

**Start / autostart**

`start_mesh.sh` exports `MESH_NAME=mesh@$(tailscale ip -4)`. For releases, also set before `bin/mesh start`:

```bash
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE="mesh@$(tailscale ip -4)"
export RELEASE_COOKIE="$(tr -d '\n' < ~/.config/mesh/cookie)"
export MESH_COOKIE="$RELEASE_COOKIE"
export MESH_NAME="$RELEASE_NODE"
```

(`MESH_NAME` feeds app config; `RELEASE_NODE` sets the Erlang `-name` in `config/vm.args.eex`.)

**After reboot**, confirm the running node did not fall back to a hostname:

```bash
curl -s http://127.0.0.1:47989/health | python3 -m json.tool | grep '"self"'
# expect: "self": "mesh@<ts-ip>"
```

If `self` is wrong, fix env and restart mesh (systemd: check `Environment=MESH_NAME=…` in `mesh.service` uses the Tailscale IP placeholder, not a hostname).

---

## 2. Cookie match

Every node must use the **same cookie bytes**. File path: `~/.config/mesh/cookie` (or `MESH_COOKIE` in the environment).

Compare hashes only — never paste cookie material into chat, tickets, or git:

```bash
sha256sum ~/.config/mesh/cookie
```

Mismatch → copy the file from a known-good node (`bin/mesh init` on one machine, then copy `~/.config/mesh/{cookie,token,nodes}` to peers). Restart mesh after updating.

---

## 3. `~/.config/mesh/nodes`

The operator CLI and `bin/mesh status` read peer addresses from `~/.config/mesh/nodes` (or `MESH_NODES`). One Tailscale IPv4 per line; optional port if HTTP is not on `47989`:

```
<ts-ip-a>
<ts-ip-b>
# <ts-ip-b> 18789   # when MESH_WEB_PORT differs (e.g. Sunshine on 47989)
```

This file drives **HTTP** reachability checks. It does not by itself connect Erlang nodes — but if a peer is missing here, you will not notice asymmetric failures from the operator path.

---

## 4. HTTP reachability (both directions)

From **node A**:

```bash
curl -sS -m 5 http://<ts-ip-b>:47989/health
```

From **node B**:

```bash
curl -sS -m 5 http://<ts-ip-a>:47989/health
```

| Pattern | Likely cause |
|---------|----------------|
| A→B works, B→A times out | Firewall or Tailscale Shields Up on **B** — not a cookie issue |
| Both time out | Mesh not listening, wrong port, or tailscale down |
| Both work, quorum still 1/1 | Erlang dist / naming / cookie / join (steps 1–2, 5–7) |

Default HTTP port is `47989` (`MESH_WEB_PORT` overrides). `bin/mesh status` labels lines `mesh` when the body contains `"quorum"`.

---

## 5. `ufw` on Linux (tailscale0)

Erlang distribution needs more than the HTTP port. On each peer, allow inbound on **`tailscale0`** (not only `eth0`):

| Port / range | Service |
|--------------|---------|
| `47989/tcp` | Mesh HTTP (`/health`, `/command`) |
| `4369/tcp` | `epmd` |
| `9000:9010/tcp` | Erlang distribution (pinned in `config/vm.args.eex`) |

Example:

```bash
sudo ufw allow in on tailscale0 to any port 47989 proto tcp
sudo ufw allow in on tailscale0 to any port 4369 proto tcp
sudo ufw allow in on tailscale0 to any port 9000:9010 proto tcp
```

**Dynamic dist ports:** this release pins `inet_dist_listen_min` / `max` to **9000–9010**. If you change that range in `vm.args` or env, ufw must cover the **actual** range. Allowing only `9100:9200` while the VM listens on `9005` will still fail.

`start_mesh.sh` sets `ERL_EPMD_ADDRESS` to the Tailscale IPv4 so epmd binds on the right interface.

---

## 6. Tailscale Shields Up (common blocker)

With **Shields Up** enabled, Tailscale blocks inbound connections to the node — even when `ufw` is correct. HTTP and Erlang dist both fail from peers.

Check:

```bash
tailscale debug prefs | grep -i ShieldsUp
# or
tailscale status --json | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('ShieldsUp'))"
```

Fix on any node that must accept mesh peers:

```bash
tailscale set --shields-up=false
```

Re-test bidirectional `curl` to `:47989` before continuing. This was the real blocker in several two-node bring-ups after ufw was already open.

---

## 7. Erlang join from the live mesh node

HTTP up + matching cookies + longnames are prerequisites. Clustering still requires an Erlang **node connection** between running mesh processes.

Connect from the **live** mesh node (the `mesh@<ts-ip>` process), not a separate throwaway node:

```bash
export MESH_COOKIE="$(tr -d '\n' < ~/.config/mesh/cookie)"
export MESH_NAME="mesh@$(tailscale ip -4)"

# shell attaches to the running mesh VM
iex --name ctl@$(tailscale ip -4) --cookie "$MESH_COOKIE" --remsh "$MESH_NAME"
```

In the remote shell:

```elixir
Node.connect(:"mesh@<peer-ts-ip>")
# or
:net_kernel.connect_node(:"mesh@<peer-ts-ip>")

Node.list()
Mesh.HealthMonitor.cluster_status()
```

**Why not only `debug@…`?** A one-off `iex --name debug@…` that calls `Node.connect/1` joins **that** ephemeral node to the peer. It does **not** connect the long-running mesh release. Quorum in `/health` stays `1/1` until the **mesh@** application node connects.

Repeat from the other side if needed (connect is not always symmetric until both sides see each other).

**Success criteria** (on **both** nodes):

```bash
curl -s http://127.0.0.1:47989/health | python3 -m json.tool
```

- `"self"` and every key under `"peers"` are `mesh@<tailscale-ipv4>` longnames  
- `"quorum": {"total": 2, "up": 2, "has_quorum": true}`  
- `"split_brain": false`

---

## Operator surfaces (unchanged by clustering)

CommandFabric **HardAllow** (`Mesh.HardAllow`, CLI `mesh allow`) stays on regardless of cluster size. Agents cannot disable the allowlist; only an operator TTL bypass applies. Reserve the word **gate** for ensembly HITL — not mesh HardAllow.

---

## Related docs

- [Getting started](getting-started.md) — build, cookie, first start  
- [Operator surface](operator-surface.md) — HTTP API, `bin/mesh`, HardAllow  
- [Architecture](architecture.md) — HealthMonitor / quorum model
