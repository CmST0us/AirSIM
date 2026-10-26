package migrations

import _ "embed"

//go:embed 001_initial.sql
var Initial string

//go:embed 002_push.sql
var Push string

//go:embed 003_pairing.sql
var Pairing string
