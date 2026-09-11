# Mesh bar + Omarchy panel

## Preferred: Omarchy panel plugin

Ship the real panel (icons, hero, stats grid, hard-allow chips):

See [`omarchy-plugin/README.md`](../omarchy-plugin/README.md).

Plugin id: `mesh` → `~/.config/omarchy/plugins/mesh/`.

## Legacy: command-module chip

Status-only chip (same shape as `focus-now` / `mm-bar-json`):

```bash
ln -sfn ~/dev/products/mesh/bin/mesh-bar ~/.local/bin/mesh-bar
# shell.json right section:
# {
#   "id": "mesh",
#   "type": "command",
#   "exec": "mesh-bar",
#   "interval": 15,
#   "onClick": "mesh-bar notify",
#   "onRightClick": "mesh-bar allow"
# }
# Reload with omarchy-restart-shell — never omarchy-refresh-shell.
```

## CLI

| Command | Output |
|---|---|
| `mesh-bar` / `status` | `{"text","tooltip","class"}` for command modules |
| `mesh-bar panel` | Rich JSON for the QML panel |
| `mesh-bar notify` | Desktop notification with quorum |
| `mesh-bar allow` | Notify daily hard-allow summary (no `mix`/`mise` — safe from the bar) |

Polls `http://127.0.0.1:${MESH_WEB_PORT:-47989}/health`.

## Naming

Public docs and git: **laptop-1** / **laptop-2**. Personal machine nicknames stay out of the repo.
