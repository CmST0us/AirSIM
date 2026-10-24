#!/bin/sh
# Local host wrapper only. Does not connect to ECS or select a deployment target.
set -eu
: "${AIRSIM_PROJECT:?explicit project required}"
: "${AIRSIM_SECRET_DIR:?}"
: "${AIRSIM_BUSINESS_IMAGE:?immutable business image reference required}"
case "$AIRSIM_BUSINESS_IMAGE" in sha256:*|*@sha256:*) ;; *) echo immutable_image_required >&2; exit 1;; esac
case " $* " in *' down '*|*' --volumes '*|*' -v '*) echo destructive_operation_not_supported >&2; exit 1;; esac
cd "$(dirname "$0")/.."
exec docker compose -p "$AIRSIM_PROJECT" -f compose.production.yaml "$@"
