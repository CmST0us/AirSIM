// at-probe is the bounded R1 investigation approved by the controller. It is not a management CLI.
package main

import (
	"airsim.local/airsim-agent/internal/at"
	"airsim.local/airsim-agent/internal/platform/rm500u"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
)

func run(formatOnly bool) (err error) {
	const marker = "/run/airsim-v2/at-inflight.json"
	if at.FencePresent(marker) {
		return fmt.Errorf("at_desynchronized")
	}
	lock, e := at.Lock("/run/airsim-v2/instance.lock")
	if e != nil {
		return e
	}
	defer lock.Close()
	port, resource, e := at.OpenDevice("/dev/smd1")
	if e != nil {
		return e
	}
	defer resource.Close()
	defer func() {
		restoreErr := port.Close()
		json.NewEncoder(os.Stdout).Encode(map[string]any{"termios_restore_ok": restoreErr == nil})
		if err == nil {
			err = restoreErr
		}
	}()
	json.NewEncoder(os.Stdout).Encode(map[string]any{"tcgets_supported": port.TTYSupported, "line_ending": "CR"})
	manager := at.New(port, marker)
	defer manager.Close()
	commands := []string{"ATI", "AT+CGMR"}
	if formatOnly {
		commands = []string{"AT+CGMR"}
	}
	for _, cmd := range commands {
		ctx, cancel := context.WithTimeout(context.Background(), 7*time.Second)
		lines, e := manager.Query(ctx, cmd)
		cancel()
		if formatOnly && e == nil {
			count := 0
			for _, line := range lines {
				if count >= 4 {
					break
				}
				if len(line) > 128 || !strings.Contains(line, "RM500") || regexp.MustCompile(`[0-9]{12,}`).MatchString(line) {
					continue
				}
				fmt.Printf("firmware_product_line=%q\n", line)
				count++
			}
		}
		match := false
		for _, line := range lines {
			if cmd == "ATI" && (line == "RM500U-CN" || line == "Model: RM500U-CN") {
				match = true
			}
			if cmd == "AT+CGMR" && (line == rm500u.Firmware || line == "Revision: "+rm500u.Firmware) {
				match = true
			}
		}
		json.NewEncoder(os.Stdout).Encode(map[string]any{"command": cmd, "query_ok": e == nil, "expected_match": match})
		if e != nil {
			return e
		}
		if !match {
			return fmt.Errorf("profile_mismatch")
		}
	}
	return nil
}
func main() {
	formatOnly := flag.Bool("firmware-format", false, "controller-authorized one-query firmware format inspection")
	flag.Parse()
	if e := run(*formatOnly); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
