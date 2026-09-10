# Source from repo scripts:  . "$(dirname "$0")/load-lab-env.sh"
# Loads gitignored .env.lab (KEY=value). Missing file is OK; required keys
# are checked by the caller.
_mesh_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${_mesh_root}/.env.lab" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${_mesh_root}/.env.lab"
  set +a
fi
unset _mesh_root
