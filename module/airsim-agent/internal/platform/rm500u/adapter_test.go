package rm500u

import (
	"airsim.local/airsim-agent/internal/at"
	"airsim.local/airsim-agent/internal/hal"
	"context"
	"testing"
)

type fake map[string][]string

func (f fake) Query(_ context.Context, c string) ([]string, error) {
	v, ok := f[c]
	if !ok {
		return nil, at.ErrQuery
	}
	return v, nil
}
func TestProfiles(t *testing.T) {
	for _, p := range []string{"", "android-avf", "eg25-embedded", "rm500", "typo"} {
		if Validate(p, "/dev/smd1", "linux", "arm64") == nil {
			t.Fatal(p)
		}
	}
	if Validate(Profile, "/dev/smd7", "linux", "arm64") == nil {
		t.Fatal("port")
	}
}
func TestReadOnlyParsers(t *testing.T) {
	a := New(fake{"ATI": {"RM500U-CN"}, "AT+CGMR": {Firmware}, "AT+CPIN?": {"+CPIN: READY"}, "AT+CSQ": {"+CSQ: 99,99"}, "AT+CREG?": {"+CREG: 2,1"}, "AT+CIREG?": {"+CIREG: 2,1"}, "AT+CLCC": {"+CLCC: 1,0,0,0,0,\"12345\",129"}})
	if a.Verify(context.Background()) != nil {
		t.Fatal("verify")
	}
	if a.Signal().Data.(hal.Signal).DBM != nil {
		t.Fatal("unknown signal converted to zero")
	}
	if a.IMS().Data.(hal.IMS).Registration != 1 {
		t.Fatal("IMS mode used")
	}
	if a.Calls().Data.(hal.Calls).Count != 1 {
		t.Fatal("calls")
	}
	if a.Registration().Data.(hal.Registration).EPS != nil {
		t.Fatal("invented eps")
	}
	a.AT = fake{}
	if a.Calls().Status != "unavailable" {
		t.Fatal("query failure invented idle")
	}
}

func TestFirmwareRejectsDifferentSuffix(t *testing.T) {
	for _, firmware := range []string{"RM500UCNAAR01A18M2G", "RM500UCNAAR01A18M2G_01.001.01.002", Firmware + "extra", "prefix" + Firmware} {
		a := New(fake{"ATI": {"RM500U-CN"}, "AT+CGMR": {firmware}})
		if a.Verify(context.Background()) == nil {
			t.Fatal("accepted unapproved firmware")
		}
	}
}
