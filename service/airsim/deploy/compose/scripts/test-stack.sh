#!/bin/sh
# Local-only isolated stack. Requires an explicit fresh external directory.
set -eu
umask 077
: "${AIRSIM_SECRET_DIR:?external fresh directory required}"
: "${GO:?absolute Go 1.24.13 executable required}"
export AIRSIM_EDGE_PORT=${AIRSIM_EDGE_PORT:-18443}
export AIRSIM_API_ORIGIN="https://api.airsim.test:$AIRSIM_EDGE_PORT"
export AIRSIM_DEVICE_ORIGIN="https://device.airsim.test:$AIRSIM_EDGE_PORT"
export AIRSIM_MEDIA_ORIGIN="https://media.airsim.test:$AIRSIM_EDGE_PORT"
export AIRSIM_UID=$(id -u) AIRSIM_GID=$(id -g)
cd "$(dirname "$0")/../../.."
"$GO" run ./cmd/airsim-test-setup --dir "$AIRSIM_SECRET_DIR" --operation tls --port "$AIRSIM_EDGE_PORT"
compose() { docker compose -p airsim-r4-test -f deploy/compose/compose.yaml "$@"; }
compose build control
compose up -d postgres
compose run --rm migrate
compose run --rm admin --operation init --secrets-dir /protected/identity
export AIRSIM_SERVER_ID=$(python3 -c 'import json,os;print(json.load(open(os.path.join(os.environ["AIRSIM_SECRET_DIR"],"identity/identity.json")))["server_id"])')
"$GO" run ./cmd/airsim-test-setup --dir "$AIRSIM_SECRET_DIR" --operation modules --port "$AIRSIM_EDGE_PORT"
for n in 1 2; do
 compose run --rm admin --operation issue-module --secrets-dir /protected/identity --request "/protected/module$n-request.json" --response "/protected/module$n-response.json" --output "/protected/module$n-bundle.json"
 compose run --rm admin --operation issue-client --output "/protected/client$n.json"
done
python3 deploy/compose/scripts/render-test-edge.py
compose up -d control media edge
compose ps --format '{{.Service}} {{.State}} {{.Health}}'
