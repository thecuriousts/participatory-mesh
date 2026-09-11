#!/usr/bin/env bash
# Run on laptop B. Completes Syncthing pairing with laptop A.
# Does not use mesh. Requires: syncthing user unit, Tailscale, filled .env.lab
set -euo pipefail

. "$(dirname "$0")/load-lab-env.sh"

need() {
  local n
  for n in "$@"; do
    if [[ -z "${!n:-}" ]]; then
      echo "missing $n — copy .env.lab.example to .env.lab and fill" >&2
      exit 1
    fi
  done
}

need ST_DEVICE_A MESH_TS_A MESH_HOST_A
FOLDER="${SYNC_FOLDER:-$HOME/sync}"
FOLDER_ID="${ST_FOLDER_ID:-sync}"
THIS_TS="$(tailscale ip -4)"

systemctl --user enable --now syncthing
sleep 1

syncthing cli config options relays-enabled set false
syncthing cli config options global-ann-enabled set false
syncthing cli config options local-ann-enabled set false
syncthing cli config options natenabled set false
syncthing cli config options start-browser set false
syncthing cli config options uraccepted set -- -1
syncthing cli config options crenabled set false
syncthing cli config options stun-keepalive-starts set -- -1
syncthing cli config options raw-listen-addresses 0 set "tcp://${THIS_TS}:22000"

THIS_ID="$(syncthing device-id)"
self0="$(syncthing cli config devices "$THIS_ID" addresses 0 get 2>/dev/null || true)"
if [[ "$self0" == "dynamic" || -z "$self0" ]]; then
  syncthing cli config devices "$THIS_ID" addresses 0 set "tcp://${THIS_TS}:22000"
fi

mkdir -p "$FOLDER"
if [[ ! -f "$FOLDER/.stignore" ]]; then
  printf '%s\n' '.git' '.DS_Store' 'lost+found' > "$FOLDER/.stignore"
fi

if ! syncthing cli config devices list | grep -q "$ST_DEVICE_A"; then
  syncthing cli config devices add \
    --device-id "$ST_DEVICE_A" \
    --name "$MESH_HOST_A" \
    --addresses "tcp://${MESH_TS_A}:22000"
fi

LOCAL_ID="$(syncthing device-id)"
export LOCAL_ID ST_DEVICE_A FOLDER FOLDER_ID
if ! syncthing cli config folders list | grep -qx "$FOLDER_ID"; then
  JSON="$(python3 - <<'PY'
import json, os
print(json.dumps({
  "id": os.environ["FOLDER_ID"],
  "label": os.environ["FOLDER_ID"],
  "filesystemType": "basic",
  "path": os.environ["FOLDER"],
  "type": "sendreceive",
  "devices": [
    {"deviceID": os.environ["LOCAL_ID"], "introducedBy": "", "encryptionPassword": ""},
    {"deviceID": os.environ["ST_DEVICE_A"], "introducedBy": "", "encryptionPassword": ""},
  ],
  "rescanIntervalS": 60,
  "fsWatcherEnabled": True,
  "fsWatcherDelayS": 10,
  "autoNormalize": True,
  "versioning": {"type": "simple", "params": {"keep": "5"}, "cleanupIntervalS": 3600, "fsPath": "", "fsType": "basic"},
  "maxConflicts": 10,
  "markerName": ".stfolder",
}))
PY
)"
  syncthing cli config folders add-json "$JSON"
fi

systemctl --user restart syncthing
sleep 2

echo "this device: $LOCAL_ID"
echo "peer ${MESH_HOST_A}: id from .env.lab; address Tailscale :22000"
echo "folder: $FOLDER (id=$FOLDER_ID)"
echo "Proof: a file in $FOLDER should appear on the other laptop."
echo "Listen should be this node's Tailscale IPv4 :22000, not *."
syncthing cli show connections | python3 -c 'import json,sys,os
d=json.load(sys.stdin)
want=os.environ["ST_DEVICE_A"]
v=d.get("connections",{}).get(want,{})
print("connected", v.get("connected"), "addr", v.get("address"))
'
