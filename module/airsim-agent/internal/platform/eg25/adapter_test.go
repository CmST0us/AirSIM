package eg25

import (
	"airsim.local/airsim-agent/internal/hal"
	"context"
	"testing"
)

type queryFixture map[string][]string

func (f queryFixture) Query(_ context.Context, cmd string) ([]string, error) { return f[cmd], nil }

func TestQDC507IdentityAndDataCalls(t *testing.T) {
	a := New(queryFixture{"ATI": {"Baiwang", "QDC507", "Revision: QDC507GLEFM21"}, "AT+CGMR": {"QDC507GLEFM21"}, "AT+CLCC": {"+CLCC: 1,1,0,1,0", "+CLCC: 2,1,0,1,0", "+CLCC: 3,1,4,0,0,\"1234567\",129"}})
	a.ReadFile = func(string) ([]byte, error) {
		return []byte("Project Name: EG25G_QDC507\nProject Sub Rev : " + Firmware + "\nBranch Name: 9x07_R07_NEW\n"), nil
	}
	if err := a.Verify(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := a.Sample(context.Background())["calls"].Data.(hal.Calls); got.Count != 1 || got.States[0] != 4 {
		t.Fatalf("voice calls: %+v", got)
	}
	calls, err := parseCalls([]string{"+CLCC: 1,1,0,1,0", "+CLCC: 3,1,4,0,0,\"1234567\",129"})
	if err != nil || len(calls) != 1 || calls[0].index != 3 || calls[0].State != "incoming" {
		t.Fatal("incorrect voice filtering")
	}
	if Validate(Profile, Device, "linux", "arm64") == nil || Validate(Profile, "/dev/smd7", "linux", "arm") == nil {
		t.Fatal("accepted incompatible platform")
	}
	if firmwareMatches("Project Name: EG25G_QDC507\nProject Sub Rev: " + Firmware + "extra") {
		t.Fatal("accepted another firmware")
	}
}
