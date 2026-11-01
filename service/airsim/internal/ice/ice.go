// Package ice issues the per-session TURN credentials that control hands to the
// App and the Agent, and verifies them in the relay. The relay keeps no session
// state: a credential is valid until the expiry embedded in its username.
package ice

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"strconv"
	"strings"
	"time"

	"airsim.local/server/internal/wire"
)

const (
	Realm    = "airsim"
	Port     = 3478
	MinRelay = 49160
	MaxRelay = 49359
	// Lifetime covers the longest media session so allocation refreshes keep
	// authenticating until the session ends.
	Lifetime = 30 * time.Minute
)

type Server struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username"`
	Credential string   `json:"credential"`
}

// Servers returns the relay endpoints for one role of one media session.
// Usernames follow the TURN REST form <expiry>:<session_id>:<role>.
func Servers(secret, host, session, role string, now time.Time) []Server {
	username := fmt.Sprintf("%d:%s:%s", now.Add(Lifetime).Unix(), session, role)
	return []Server{{
		URLs:       []string{fmt.Sprintf("turn:%s:%d?transport=udp", host, Port), fmt.Sprintf("turn:%s:%d?transport=tcp", host, Port)},
		Username:   username,
		Credential: Password(secret, username),
	}}
}

func Password(secret, username string) string {
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(username))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// Valid reports whether username is a well-formed, unexpired session credential.
func Valid(username string, now time.Time) bool {
	parts := strings.Split(username, ":")
	if len(parts) != 3 || !wire.UUID.MatchString(parts[1]) || (parts[2] != "client" && parts[2] != "agent") {
		return false
	}
	expiry, e := strconv.ParseInt(parts[0], 10, 64)
	return e == nil && now.Unix() < expiry && time.Unix(expiry, 0).Sub(now) <= Lifetime
}
