ALTER TABLE clients ADD COLUMN module_id uuid REFERENCES modules(id);
ALTER TABLE clients ADD COLUMN refresh_hash text UNIQUE;
ALTER TABLE clients ADD COLUMN refresh_expires_at timestamptz;
ALTER TABLE clients ADD CONSTRAINT client_session_scope CHECK (
 (module_id IS NULL AND refresh_hash IS NULL AND refresh_expires_at IS NULL) OR
 (module_id IS NOT NULL AND refresh_hash IS NOT NULL AND refresh_expires_at IS NOT NULL)
);
CREATE TABLE pairing_requests (
 id uuid PRIMARY KEY, module_id uuid NOT NULL REFERENCES modules(id), server_id uuid NOT NULL,
 poll_hash text NOT NULL, nonce text NOT NULL, expires_at timestamptz NOT NULL,
 state text NOT NULL CHECK(state IN ('awaiting_device','awaiting_phone','connected','cancelled')),
 code_hash text UNIQUE, code_cipher bytea, proof bytea,
 claim_id uuid, client_id uuid REFERENCES clients(id)
);
CREATE INDEX pairing_pending ON pairing_requests(module_id,expires_at) WHERE state IN ('awaiting_device','awaiting_phone');
INSERT INTO schema_version(version) VALUES(3);
