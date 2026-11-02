package eg25

import (
	"airsim.local/airsim-agent/internal/at"
	"context"
	"testing"
)

type maintenancePort struct {
	storage string
	writes  int
	fail    bool
}

func (p *maintenancePort) Done() <-chan struct{} { return nil }
func (p *maintenancePort) Query(context.Context, string) ([]string, error) {
	return []string{p.storage}, nil
}
func (p *maintenancePort) Command(_ context.Context, command, payload string) ([]string, error) {
	if command != "AT+CMGD=1,4" || payload != "" {
		panic("unexpected write")
	}
	p.writes++
	if p.fail {
		return nil, at.ErrDesynchronized
	}
	p.storage = `+CPMS: "ME",0,23,"ME",0,23,"ME",0,23`
	return nil, nil
}
func TestMaintenanceRequiresExactConfirmedStorageAndNeverRetries(t *testing.T) {
	const full = `+CPMS: "ME",23,23,"ME",23,23,"ME",23,23`
	for _, storage := range []string{`+CPMS: "SM",23,23,"SM",23,23,"SM",23,23`, `+CPMS: "ME",22,23,"ME",22,23,"ME",22,23`, "invalid"} {
		p := &maintenancePort{storage: storage}
		if _, err := ClearStoredME(context.Background(), p, 23, 23); err == nil || p.writes != 0 {
			t.Fatal("unconfirmed storage deleted")
		}
	}
	p := &maintenancePort{storage: full}
	if _, err := ClearStoredME(context.Background(), p, 0, 23); err == nil || p.writes != 0 {
		t.Fatal("confirmation omitted")
	}
	after, err := ClearStoredME(context.Background(), p, 23, 23)
	if err != nil || p.writes != 1 || after.Receive.Used != 0 {
		t.Fatal("clear verification failed")
	}
	p = &maintenancePort{storage: full, fail: true}
	if _, err := ClearStoredME(context.Background(), p, 23, 23); err == nil || p.writes != 1 {
		t.Fatal("uncertain operation retried")
	}
}
