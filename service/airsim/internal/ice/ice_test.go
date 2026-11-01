package ice

import (
	"strconv"
	"strings"
	"testing"
	"time"

	"airsim.local/server/internal/wire"
)

func TestServersIssueVerifiableCredential(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	session := wire.ID()
	servers := Servers("secret", "203.0.113.7", session, "agent", now)
	if len(servers) != 1 || len(servers[0].URLs) != 2 || servers[0].URLs[0] != "turn:203.0.113.7:3478?transport=udp" || servers[0].URLs[1] != "turn:203.0.113.7:3478?transport=tcp" {
		t.Fatalf("servers %+v", servers)
	}
	u := servers[0].Username
	if !strings.HasSuffix(u, ":"+session+":agent") || !Valid(u, now) || servers[0].Credential != Password("secret", u) || servers[0].Credential == Password("other", u) {
		t.Fatalf("credential %+v", servers[0])
	}
	if Valid(u, now.Add(Lifetime)) {
		t.Fatal("expired credential accepted")
	}
}

func TestValidRejectsMalformedUsernames(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	session := wire.ID()
	future := now.Add(time.Minute).Unix()
	for _, u := range []string{
		"",
		"1800000060",
		"x:" + session + ":client",
		strings.Join([]string{"1800000060", "not-a-uuid", "client"}, ":"),
		strings.Join([]string{"1800000060", session, "admin"}, ":"),
		strings.Join([]string{"1800000060", session, "client", "extra"}, ":"),
		// An expiry further out than any issued credential is not ours.
		strings.Join([]string{"1900000000", session, "client"}, ":"),
	} {
		if Valid(u, now) {
			t.Fatalf("accepted %q", u)
		}
	}
	if !Valid(strings.Join([]string{strconv.FormatInt(future, 10), session, "client"}, ":"), now) {
		t.Fatal("valid credential rejected")
	}
}
