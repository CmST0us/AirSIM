package migrations

import _ "embed"

//go:embed 001_initial.sql
var Initial string

//go:embed 002_push.sql
var Push string

//go:embed 003_pairing.sql
var Pairing string

//go:embed 004_persistent_client_sessions.sql
var PersistentClientSessions string

//go:embed 005_permanent_module_sessions.sql
var PermanentModuleSessions string

//go:embed 006_pairing_reset.sql
var PairingReset string
