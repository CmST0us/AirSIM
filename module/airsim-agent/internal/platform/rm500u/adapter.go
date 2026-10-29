package rm500u

import (
	"airsim.local/airsim-agent/internal/platform/atmodem"
	"context"
	"fmt"
)

const Profile = "rm500u-embedded"
const Firmware = "RM500UCNAAR01A18M2G_01.001.01.001"

func Validate(profile, device, goos, arch string) error {
	if profile != Profile || device != "/dev/smd1" || goos != "linux" || arch != "arm64" {
		return fmt.Errorf("profile_mismatch")
	}
	return nil
}

type Adapter struct{ atmodem.Adapter }

func New(q atmodem.Querier) *Adapter { return &Adapter{atmodem.Adapter{AT: q}} }

func (a *Adapter) Verify(ctx context.Context) error {
	lines, e := a.AT.Query(ctx, "ATI")
	if e != nil {
		return e
	}
	found := false
	for _, l := range lines {
		if l == "RM500U-CN" || l == "Model: RM500U-CN" {
			found = true
		}
	}
	if !found {
		return fmt.Errorf("profile_mismatch")
	}
	lines, e = a.AT.Query(ctx, "AT+CGMR")
	if e != nil {
		return e
	}
	for _, l := range lines {
		if l == Firmware || l == "Revision: "+Firmware {
			return nil
		}
	}
	return fmt.Errorf("profile_mismatch")
}
