package eg25

import (
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/platform/atmodem"
	"context"
	"errors"
	"os"
	"strings"
	"time"
)

const Profile = "eg25-qdc507"
const Firmware = "QDC507GLEFM21_02.004.03"
const Device = "/dev/airsim_data11"

type Adapter struct {
	atmodem.Adapter
	ReadFile func(string) ([]byte, error)
}

func New(q atmodem.Querier) *Adapter {
	return &Adapter{Adapter: atmodem.Adapter{AT: q, VoiceOnly: true}, ReadFile: os.ReadFile}
}

func Validate(profile, device, goos, arch string) error {
	if profile != Profile || device != Device || goos != "linux" || arch != "arm" {
		return errors.New("profile_mismatch")
	}
	return nil
}

func (a *Adapter) Verify(ctx context.Context) error {
	b, err := a.ReadFile("/etc/quectel-project-subversion")
	if err != nil || !firmwareMatches(string(b)) {
		return errors.New("profile_mismatch")
	}
	lines, err := a.AT.Query(ctx, "ATI")
	if err != nil {
		return err
	}
	found := false
	for _, line := range lines {
		if line == "QDC507" {
			found = true
		}
	}
	if !found {
		return errors.New("profile_mismatch")
	}
	lines, err = a.AT.Query(ctx, "AT+CGMR")
	if err != nil {
		return err
	}
	for _, line := range lines {
		if line == "QDC507GLEFM21" {
			return nil
		}
	}
	return errors.New("profile_mismatch")
}

func firmwareMatches(text string) bool {
	project, revision := "", ""
	for _, line := range strings.Split(text, "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "Project Name":
			project = strings.TrimSpace(value)
		case "Project Sub Rev":
			revision = strings.TrimSpace(value)
		}
	}
	return project == "EG25G_QDC507" && revision == Firmware
}

func (a *Adapter) IMS() hal.Field { return hal.Unavailable("at", "not_supported") }
func (a *Adapter) Sample(ctx context.Context) map[string]hal.Field {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	b := a.WithContext(ctx)
	return map[string]hal.Field{"sim": b.SIM(), "signal": b.Signal(), "registration": b.Registration(), "ims": a.IMS(), "calls": b.Calls(), "network": b.Network(), "platform": b.Platform()}
}
