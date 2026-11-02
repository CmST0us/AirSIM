// sms-maintenance is an offline maintenance tool, not part of the Engine
// package. Clearing requires explicit operator approval and stopped Agent.
package main

import (
	"airsim.local/airsim-agent/internal/at"
	"airsim.local/airsim-agent/internal/platform/eg25"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"runtime"
	"time"
)

func run(confirm bool, used, total int) error {
	if !confirm || used < 1 || total < used {
		return errors.New("confirmation_required")
	}
	if err := eg25.Validate(eg25.Profile, eg25.Device, runtime.GOOS, runtime.GOARCH); err != nil {
		return err
	}
	for _, path := range []string{"/usrdata/airsim-v2/instance.lock", "/run/airsim-v2/instance.lock"} {
		lock, err := at.Lock(path)
		if err != nil {
			return err
		}
		defer lock.Close()
	}
	const marker = "/run/airsim-v2/at-inflight.json"
	if at.FencePresent(marker) {
		return at.ErrDesynchronized
	}
	port, lock, err := at.OpenDevice(eg25.Device)
	if err != nil {
		return err
	}
	defer lock.Close()
	defer port.Close()
	manager := at.New(port, marker)
	defer manager.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err = eg25.New(manager).Verify(ctx); err != nil {
		return err
	}
	after, err := eg25.ClearStoredME(ctx, manager, used, total)
	if err != nil {
		return err
	}
	manager.GracefulClose()
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"clear_command_accepted": true, "storage_after": after})
}

func main() {
	confirm := flag.Bool("confirm-clear-me", false, "operator approved deleting all records in the currently selected ME store")
	used := flag.Int("expected-used", 0, "confirmed occupied record count")
	total := flag.Int("expected-total", 0, "confirmed capacity")
	flag.Parse()
	if err := run(*confirm, *used, *total); err != nil {
		// All values are fixed operation error codes; no SMS data is read.
		fmt.Fprintln(os.Stderr, "sms_maintenance_failed")
		os.Exit(1)
	}
}
