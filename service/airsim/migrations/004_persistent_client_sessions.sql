ALTER TABLE clients DROP CONSTRAINT client_session_scope;
ALTER TABLE clients ADD CONSTRAINT client_session_scope CHECK (
 (module_id IS NULL AND refresh_hash IS NULL AND refresh_expires_at IS NULL) OR
 (module_id IS NOT NULL AND refresh_hash IS NOT NULL)
);
UPDATE clients SET refresh_expires_at=NULL
 WHERE module_id IS NOT NULL AND refresh_hash IS NOT NULL AND NOT revoked;
INSERT INTO schema_version(version) VALUES(4);
