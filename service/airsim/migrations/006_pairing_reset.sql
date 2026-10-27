ALTER TABLE pairing_requests
ADD COLUMN replace_existing boolean NOT NULL DEFAULT false;

INSERT INTO schema_version(version) VALUES(6);
