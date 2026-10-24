#!/bin/sh
# Only the explicitly isolated local test project; never targets production volumes.
set -eu
umask 077
: "${AIRSIM_SECRET_DIR:?}"
: "${AIRSIM_BACKUP_FILE:?explicit new external dump path required}"
restore_db=${AIRSIM_RESTORE_DATABASE:-airsim_r4_restore}
case "$restore_db" in airsim_r4_restore*) ;; *) echo invalid_restore_database >&2; exit 1;; esac
case "$restore_db" in *[!a-z0-9_]*) echo invalid_restore_database >&2; exit 1;; esac
[ ! -e "$AIRSIM_BACKUP_FILE" ] || { echo backup_exists >&2; exit 1; }
cd "$(dirname "$0")"
./local-compose.sh exec -T postgres pg_dump -U airsim -d airsim -Fc > "$AIRSIM_BACKUP_FILE"
./local-compose.sh exec -T postgres createdb -U airsim "$restore_db"
./local-compose.sh exec -T postgres pg_restore -U airsim -d "$restore_db" --exit-on-error < "$AIRSIM_BACKUP_FILE"
for table in schema_version identity clients modules provisions commands reservations; do
 query="SELECT md5(COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text,'')) FROM $table t;"
 source_hash=$(./local-compose.sh exec -T postgres psql -X -U airsim -d airsim -At -v ON_ERROR_STOP=1 -c "$query")
 restored_hash=$(./local-compose.sh exec -T postgres psql -X -U airsim -d "$restore_db" -At -v ON_ERROR_STOP=1 -c "$query")
 [ "$source_hash" = "$restored_hash" ] || { echo "restore_mismatch:$table" >&2; exit 1; }
 printf '%s\n' "restore_equal:$table"
done
# Keep restored database for inspection; no service connects to it.
