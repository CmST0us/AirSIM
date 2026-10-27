ALTER TABLE clients ALTER COLUMN expires_at DROP NOT NULL;
ALTER TABLE clients ADD COLUMN paired_at timestamptz;

WITH ranked AS (
 SELECT c.id,
        c.module_id,
        p.last_connected,
        row_number() OVER (
            PARTITION BY c.module_id
            ORDER BY p.last_connected DESC NULLS LAST, c.id DESC
        ) AS rank
 FROM clients c
 LEFT JOIN LATERAL (
     SELECT max(pr.expires_at) AS last_connected
     FROM pairing_requests pr
     WHERE pr.client_id=c.id AND pr.state='connected'
 ) p ON true
 WHERE c.module_id IS NOT NULL AND NOT c.revoked
)
UPDATE clients c
SET paired_at=COALESCE(r.last_connected, now()),
    revoked=(r.rank > 1)
FROM ranked r
WHERE c.id=r.id;

UPDATE clients
SET paired_at=COALESCE(paired_at, now())
WHERE module_id IS NOT NULL;

UPDATE clients
SET expires_at=NULL, refresh_expires_at=NULL
WHERE module_id IS NOT NULL AND NOT revoked;

CREATE UNIQUE INDEX clients_one_active_per_module
ON clients(module_id)
WHERE module_id IS NOT NULL AND NOT revoked;

INSERT INTO schema_version(version) VALUES(5);
