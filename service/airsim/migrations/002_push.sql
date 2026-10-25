CREATE TABLE push_registrations (
 client_id uuid PRIMARY KEY REFERENCES clients(id), registration_id uuid NOT NULL UNIQUE,
 module_id uuid NOT NULL REFERENCES modules(id), bundle_id text NOT NULL,
 environment text NOT NULL CHECK(environment IN ('sandbox','production')),
 voip_token text NOT NULL, alert_token text NOT NULL, registered_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE push_calls (
 module_id uuid NOT NULL REFERENCES modules(id), agent_boot_id uuid NOT NULL, backend_epoch uuid NOT NULL,
 call_id uuid NOT NULL, call_uuid uuid NOT NULL UNIQUE, last_seen timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(module_id,agent_boot_id,backend_epoch,call_id)
);
CREATE TABLE push_deliveries (
 registration_id uuid NOT NULL REFERENCES push_registrations(registration_id) ON DELETE CASCADE,
 module_id uuid NOT NULL, agent_boot_id uuid NOT NULL, backend_epoch uuid NOT NULL,
 event text NOT NULL, event_id text NOT NULL, attempts integer NOT NULL DEFAULT 0,
 finished boolean NOT NULL DEFAULT false, expires_at timestamptz NOT NULL DEFAULT now()+interval '30 seconds',
 next_attempt timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(registration_id,module_id,agent_boot_id,backend_epoch,event,event_id)
);
INSERT INTO schema_version(version) VALUES(2);
