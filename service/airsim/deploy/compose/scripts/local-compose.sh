#!/bin/sh
set -eu
: "${AIRSIM_SECRET_DIR:?}"
export AIRSIM_EDGE_PORT=${AIRSIM_EDGE_PORT:-18443}
export AIRSIM_API_ORIGIN="https://api.airsim.test:$AIRSIM_EDGE_PORT" AIRSIM_DEVICE_ORIGIN="https://device.airsim.test:$AIRSIM_EDGE_PORT" AIRSIM_MEDIA_ORIGIN="https://media.airsim.test:$AIRSIM_EDGE_PORT"
export AIRSIM_UID=$(id -u) AIRSIM_GID=$(id -g)
if [ -f "$AIRSIM_SECRET_DIR/identity/identity.json" ]; then
 export AIRSIM_SERVER_ID=$(python3 -c 'import json,os;print(json.load(open(os.path.join(os.environ["AIRSIM_SECRET_DIR"],"identity/identity.json")))["server_id"])')
fi
project=${AIRSIM_TEST_PROJECT:-airsim-r4-test}
cd "$(dirname "$0")/../../.."
exec docker compose -p "$project" -f deploy/compose/compose.yaml "$@"
