# Cluster troubleshooting — two nodes, quorum stuck at 1/1

Both laptops answer `GET /health` on `:47989`, but each node reports **quorum 1/1** (or `has_quorum: false` with only `self` in `peers`). HTTP is up; **Erlang distribution** is not joined. Work through the sections below in order.

## Quick checklist

| # | Check | Pass looks like |
|---|--------|-----------------|
| 1 | Node name is `mesh@<tailscale-ipv4>` on **both** machines | `/health` → `"self": "mesh@100.x.x.x"` matches that machine's Tailscale IPv4 |
| 2 | Cookie bytes match | `sha256sum ~/.config/mesh/cookie` identical on both nodes (never paste the cookie) |
| 3 | `~/.config/mesh/nodes` lists peer Tailscale IPv4s | `bin/mesh status` hits both nodes |
| 4 | HTTP works **both directions** | `curl http://<peer-ip>:47989/health` succeeds from each laptop |
| 5 | `ufw` allows Tailscale + OTP ports | `ufw status` shows `47989`, `4369`, `9100:9200/tcp` on `tailscale0` |
| 6 | Tailscale Shields Up is off | `tailscale debug prefs` → `ShieldsUp: false` (or `tailscale set --shields-up=false`) |
| 7 | `Node.connect` from the **running** `mesh@` node | `Node.list()` on each side includes the peer after connect |
| 8 | Beam listens on dist port | `ss -lntp \| grep beam` shows `*:9100` (or your pinned min) after restart |

If steps 1–4 pass but 7 fails, the problem is almost always firewall, Shields Up, or OTP distribution ports — not the cookie.

---

## 1. Longname vs shortname

Distributed Erlang needs a **long node name** that matches how peers reach you on Tailscale.

**Use everywhere:**

```text
mesh@<tailscale-ipv4>
```

Examples of placeholders: `mesh@100.x.x.x` — never `mesh@laptop-a`, `mesh@localhost`, or a hostname that does not resolve the same on both sides.

**Release / startup**

| Mechanism | Set |
|-----------|-----|
| `start_mesh.sh` | `export MESH_NAME="mesh@$(tailscale ip -4)"` before start |
| Mix release | `RELEASE_DISTRIBUTION=name` and `RELEASE_NODE=mesh@<tailscale-ipv4>` (or equivalent in `vm.args`) |
| systemd | Same values in the unit env file |

**After every reboot**, confirm the running node name before debugging join:

```bash
curl -s http://127.0.0.1:47989/health | jq '.self'
# expect: "mesh@<this-machine-tailscale-ipv4>"
```

If `self` shows the wrong IP or a short name, fix `MESH_NAME` / `RELEASE_NODE` and restart mesh. Two nodes with mismatched naming never appear in each other's `Node.list()`.

---

## 2. Cookie match

The Erlang magic cookie must be **the same bytes** on every node.

**Location:** `~/.config/mesh/cookie` (chmod `600`). `start_mesh.sh` and the release read `MESH_COOKIE` or this file.

**Compare without exposing the secret:**

```bash
sha256sum ~/.config/mesh/cookie
```

Run on **both** laptops. Digests must match exactly. If they differ, copy the file from one machine to the other (same bytes) or regenerate once and redeploy to both — do **not** paste the cookie into chat, tickets, or docs.

Cookie mismatch breaks `Node.connect` and `--remsh`; it does **not** explain one-way HTTP failure (HTTP does not use the cookie).

---

## 3. `~/.config/mesh/nodes`

`bin/mesh status` and operator HTTP checks use this file (or `MESH_NODES`) to know which peers to probe.

**Format:** one Tailscale IPv4 per line, or `ip port` if mesh listens on a non-default port:

```text
100.x.x.x
100.y.y.y
```

Populate with peer **Tailscale IPv4s**, not hostnames. After `bin/mesh init`, copy `token`, `cookie`, `nodes`, and `allowed_services` to the other laptop as the **same bytes** (see [Getting started](getting-started.md)).

```bash
bin/mesh status
```

You should see JSON from `/health` on every listed IP. This file does not configure Erlang clustering by itself — it only drives operator-side HTTP checks.

---

## 4. Bidirectional HTTP

`/health` returning 200 on localhost does not prove the **peer** can reach you.

From **laptop A**:

```bash
curl -sS -m 3 http://<laptop-b-tailscale-ipv4>:47989/health
```

From **laptop B**:

```bash
curl -sS -m 3 http://<laptop-a-tailscale-ipv4>:47989/health
```

| Symptom | Likely cause |
|---------|----------------|
| A → B works, B → A times out | Firewall or **Tailscale Shields Up** on A (inbound blocked) |
| Neither direction works | Wrong IP in `nodes`, mesh not listening, or wrong `MESH_WEB_PORT` |
| Both directions work, quorum still 1/1 | OTP distribution (sections 5–8), not cookie |

Asymmetric reachability is a **network / inbound policy** problem, not an allowlist or HardAllow issue.

---

## 5. `ufw` on `tailscale0`

Mesh needs inbound TCP on the Tailscale interface for HTTP, EPMD, and Erlang distribution.

**Allow on `tailscale0` (placeholders for peer IPs):**

| Port | Service |
|------|---------|
| `47989/tcp` | Mesh HTTP (`/health`, `/command`) |
| `4369/tcp` | EPMD (node name registration) |
| `9100:9200/tcp` | Erlang distribution (OTP dist) |

```bash
sudo ufw allow in on tailscale0 to any port 47989 proto tcp
sudo ufw allow in on tailscale0 to any port 4369 proto tcp
sudo ufw allow in on tailscale0 to any port 9100:9200 proto tcp
sudo ufw reload
```

**Do not** use `9000:9010` for a pinned two-node lab unless you have explicitly configured that range everywhere. Default release `vm.args` may ship a different range; operators should **pin** dist ports to `9100:9200` and open the same range in `ufw`.

**Pin the beam listen range** (pick one path and use the same on both nodes):

```bash
export ELIXIR_ERL_OPTIONS='-kernel inet_dist_listen_min 9100 -kernel inet_dist_listen_max 9200'
```

Release: add the same `-kernel` lines to `vm.args` or `env.sh`. systemd example:

```ini
Environment="ELIXIR_ERL_OPTIONS=-kernel inet_dist_listen_min 9100 -kernel inet_dist_listen_max 9200"
```

(Keep quotes so the shell passes both `-kernel` flags correctly.)

**Verify after restart:**

```bash
ss -lntp | grep beam
# expect a LISTEN on *:9100 (or your inet_dist_listen_min)
```

If HTTP is open but dist is not, `Node.connect` fails while `curl /health` still works.

---

## 6. Tailscale Shields Up

`ufw` can be correct and peers still cannot open inbound connections if **Shields Up** is enabled on a node. Tailscale blocks incoming traffic to that machine except what Tailscale itself needs.

**Check:**

```bash
tailscale debug prefs | grep -i shields
```

**Fix (on each mesh node):**

```bash
tailscale set --shields-up=false
```

Re-test **bidirectional** `curl` (section 4). Shields Up on one side produces exactly the asymmetric pattern: peer can curl you, you cannot curl them (or the reverse).

---

## 7. Erlang join from the live `mesh@` node

`Node.connect/1` must run in the **same Erlang node as the running mesh release**, not a throwaway shell.

**Wrong:** `iex --name debug@100.x.x.x` or `ctl@…` with a different node name — that is a separate VM; it does not fix the mesh application's cluster view.

**Right:** attach to the running release node:

```bash
export MESH_COOKIE="$(tr -d '\n' < ~/.config/mesh/cookie)"
export MESH_NAME="mesh@$(tailscale ip -4)"
_build/prod/rel/mesh/bin/mesh remote_console
```

Or, if you use `start_mesh.sh` / systemd, `--remsh` must target the **live** `mesh@<tailscale-ipv4>`:

```bash
iex --name "mesh@$(tailscale ip -4)" --cookie "$MESH_COOKIE" --remsh "$MESH_NAME"
```

(Use a distinct **temporary** name only for the client side of `--remsh`, e.g. `remsh@$(tailscale ip -4)` — the **target** must be the running `mesh@…` node.)

**On laptop A** (after remote console is attached to A's mesh node):

```elixir
Node.connect(:"mesh@<laptop-b-tailscale-ipv4>")
Node.list()
Mesh.HealthMonitor.cluster_status()
```

Repeat from B toward A if needed. Successful join shows the peer in `Node.list()` and quorum moving toward **2/2** with `has_quorum: true` on a two-node cluster.

If `Node.connect` returns `false` or `:ignored`, go back to cookie (section 2), dist ports (section 5), and Shields Up (section 6) before retrying.

---

## Related docs

- [Getting started](getting-started.md) — build, cookie, first start
- [Operator surface](operator-surface.md) — allowlisted commands, HardAllow, HTTP API
