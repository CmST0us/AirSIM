
CREATE TABLE IF NOT EXISTS schema_version(version integer PRIMARY KEY);
CREATE TABLE IF NOT EXISTS identity(singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),server_id uuid NOT NULL UNIQUE,user_id uuid NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS clients(id uuid PRIMARY KEY,user_id uuid NOT NULL,token_hash text NOT NULL UNIQUE,expires_at timestamptz NOT NULL,revoked boolean NOT NULL DEFAULT false);
CREATE TABLE IF NOT EXISTS modules(id uuid PRIMARY KEY,user_id uuid NOT NULL,server_id uuid NOT NULL,public_key bytea NOT NULL,serial text NOT NULL,certificate text NOT NULL,revoked boolean NOT NULL DEFAULT false);
CREATE TABLE IF NOT EXISTS provisions(request_id uuid PRIMARY KEY,module_id uuid NOT NULL REFERENCES modules(id),request_digest text NOT NULL,bundle jsonb NOT NULL);
CREATE TABLE IF NOT EXISTS commands(id uuid PRIMARY KEY,module_id uuid NOT NULL REFERENCES modules(id),user_id uuid NOT NULL,client_id uuid NOT NULL REFERENCES clients(id),connection_epoch uuid NOT NULL,generation uuid NOT NULL,request_hmac text NOT NULL,action text NOT NULL,state text NOT NULL CHECK(state IN ('pending','dispatched','completed','outcome_unknown')),receipt jsonb,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS commands_module ON commands(module_id);
CREATE TABLE IF NOT EXISTS reservations(module_id uuid PRIMARY KEY REFERENCES modules(id),client_id uuid NOT NULL REFERENCES clients(id),generation uuid NOT NULL,agent_boot_id uuid NOT NULL,backend_epoch uuid NOT NULL,call_id uuid,command_id uuid NOT NULL REFERENCES commands(id));
INSERT INTO schema_version(version) VALUES(1) ON CONFLICT DO NOTHING;
