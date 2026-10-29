#!/bin/sh
# Local host wrapper only. Does not connect to ECS or select a deployment target.
set -eu
: "${AIRSIM_PROJECT:?explicit project required}"
: "${AIRSIM_SECRET_DIR:?}"
: "${AIRSIM_BUSINESS_IMAGE:?immutable business image reference required}"
case "$AIRSIM_BUSINESS_IMAGE" in sha256:*|*@sha256:*) ;; *) echo immutable_image_required >&2; exit 1;; esac
case " $* " in *' down '*|*' --volumes '*|*' -v '*) echo destructive_operation_not_supported >&2; exit 1;; esac
cd "$(dirname "$0")/.."
if [ -n "${AIRSIM_APNS_SANDBOX_KEY_PATH:-}${AIRSIM_APNS_PRODUCTION_KEY_PATH:-}" ]; then
 if [ -n "${AIRSIM_APNS_KEY_PATH:-}" ]; then
  echo apns_config_mixed_keys >&2; exit 1
 fi
 exec docker compose -p "$AIRSIM_PROJECT" -f compose.production.yaml -f compose.apns-environments.yaml "$@"
fi
if [ -n "${AIRSIM_APNS_KEY_PATH:-}" ]; then
 exec docker compose -p "$AIRSIM_PROJECT" -f compose.production.yaml -f compose.apns.yaml "$@"
fi
exec docker compose -p "$AIRSIM_PROJECT" -f compose.production.yaml "$@"
