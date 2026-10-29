package control

import (
	"airsim.local/server/internal/wire"
	"strings"
	"testing"
	"time"
)

func TestPairingCodeEncryptionAndDomainSeparation(t *testing.T) {
	server := New(nil, Config{HMAC: wire.Token()})
	code := "00427193"
	sealed, err := server.sealPairingCode(code)
	if err != nil {
		t.Fatal(err)
	}
	opened, err := server.openPairingCode(sealed)
	if err != nil || opened != code {
		t.Fatal("pairing code round trip")
	}
	other := New(nil, Config{HMAC: wire.Token()})
	if _, err := other.openPairingCode(sealed); err == nil {
		t.Fatal("different HMAC root opened pairing code")
	}
	if server.pairingCodeHash(code) == wire.Hash(code) {
		t.Fatal("pairing code hash was not domain separated")
	}
	if server.pairingCodeHash(code) != server.pairingCodeHash(code) {
		t.Fatal("pairing code hash is not stable")
	}
}

func TestPairingRateWindowAndCapacity(t *testing.T) {
	var limiter pairingLimiter
	now := time.Now()
	for i := 0; i < 8; i++ {
		if !limiter.allow("source", 8, now) {
			t.Fatalf("request %d rejected", i)
		}
	}
	if limiter.allow("source", 8, now) {
		t.Fatal("ninth request accepted")
	}
	if !limiter.allow("source", 8, now.Add(time.Minute)) {
		t.Fatal("window did not reset")
	}
	for i := 0; i < 1023; i++ {
		limiter.allow("key-"+leftPadDecimal(int64(i), 4), 8, now.Add(time.Minute))
	}
	if limiter.allow("overflow", 8, now.Add(time.Minute)) {
		t.Fatal("unbounded source map")
	}
}

func TestPairingDecimalCodePadding(t *testing.T) {
	for input, expected := range map[int64]string{0: "00000000", 1: "00000001", 99999999: "99999999"} {
		if actual := leftPadDecimal(input, 8); actual != expected {
			t.Fatalf("%d: %s", input, actual)
		}
	}
	if !codePattern.MatchString("00427193") || codePattern.MatchString(strings.Repeat("1", 7)) {
		t.Fatal("code length")
	}
}

func TestPairingUsesAuthenticatedPlatformName(t *testing.T) {
	s := New(nil, Config{})
	if s.moduleName("offline") != "AirSIM" {
		t.Fatal("unknown module was assigned a model")
	}
	s.last["eg25"] = &peer{platform: "eg25-qdc507"}
	s.last["rm500"] = &peer{platform: "rm500u-embedded"}
	if s.moduleName("eg25") != "EG25 QDC507" || s.moduleName("rm500") != "RM500U" {
		t.Fatal("model not retained for pairing")
	}
}
