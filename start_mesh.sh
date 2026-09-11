#!/usr/bin/env bash
# Mesh cluster startup script
# Usage: ./start_mesh.sh [node_name]

set -euo pipefail

MESH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$MESH_DIR"

# Configuration — cookie must be identical on every node (never generate here)
if [[ -z "${MESH_COOKIE:-}" && -f "${HOME}/.config/mesh/cookie" ]]; then
    MESH_COOKIE="$(tr -d '\n' < "${HOME}/.config/mesh/cookie")"
fi
if [[ -z "${MESH_COOKIE:-}" ]]; then
    echo "MESH_COOKIE missing. Run:  bin/mesh init" >&2
    exit 1
fi
COOKIE="$MESH_COOKIE"
NODE_NAME="${1:-mesh@$(tailscale ip -4 2>/dev/null || hostname)}"
TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")"
DATA_DIR="${MESH_DATA_DIR:-$HOME/.local/share/mesh}"
LOG_DIR="${MESH_LOG_DIR:-$HOME/.local/share/mesh/logs}"

mkdir -p "$DATA_DIR/mnesia" "$LOG_DIR"

export MESH_COOKIE="$COOKIE"
export MESH_NAME="$NODE_NAME"
export TAILSCALE_IP="$TAILSCALE_IP"
export MESH_DATA_DIR="$DATA_DIR"
export MESH_LOG_DIR="$LOG_DIR"

# Ensure EPMD runs on Tailscale interface
export ERL_EPMD_ADDRESS="$TAILSCALE_IP"

echo "Starting Mesh node: $NODE_NAME"
echo "Tailscale IP: $TAILSCALE_IP"
echo "Data dir: $DATA_DIR"

# Check if release exists
RELEASE_DIR="$MESH_DIR/_build/prod/rel/mesh"
if [[ ! -d "$RELEASE_DIR" ]]; then
    echo "Building release..."
    mix deps.get --only prod
    MIX_ENV=prod mix compile
    MIX_ENV=prod mix release --overwrite
fi

# Start the release
exec "$RELEASE_DIR/bin/mesh" start