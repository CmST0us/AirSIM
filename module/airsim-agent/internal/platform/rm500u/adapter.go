package rm500u

import (
	"airsim.local/airsim-agent/internal/at"
	"airsim.local/airsim-agent/internal/hal"
	"context"
	"encoding/csv"
	"fmt"
	"net"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const Profile = "rm500u-embedded"
const Firmware = "RM500UCNAAR01A18M2G_01.001.01.001"

func Validate(profile, device, goos, arch string) error {
	if profile != Profile || device != "/dev/smd1" || goos != "linux" || arch != "arm64" {
		return fmt.Errorf("profile_mismatch")
	}
	return nil
}

type Querier interface {
	Query(context.Context, string) ([]string, error)
}
type Adapter struct {
	AT  Querier
	ctx context.Context
}

func (a *Adapter) WithContext(ctx context.Context) *Adapter { return &Adapter{a.AT, ctx} }
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
func (a *Adapter) query(cmd string, parse func([]string) (any, error)) hal.Field {
	lines, e := a.AT.Query(a.ctx, cmd)
	if e != nil {
		code := "query_failed"
		if e == at.ErrDesynchronized {
			code = "at_desynchronized"
		}
		return hal.Unavailable("at", code)
	}
	data, e := parse(lines)
	if e != nil {
		return hal.Unavailable("at", "invalid_response")
	}
	return hal.Available("at", data)
}
func parts(lines []string, prefix string) ([]string, error) {
	if len(lines) != 1 || !strings.HasPrefix(lines[0], prefix) {
		return nil, at.ErrInvalid
	}
	return csv.NewReader(strings.NewReader(strings.TrimSpace(strings.TrimPrefix(lines[0], prefix)))).Read()
}
func number(s string, min, max int) (int, error) {
	n, e := strconv.Atoi(strings.TrimSpace(s))
	if e != nil || n < min || n > max {
		return 0, at.ErrInvalid
	}
	return n, nil
}
func (a *Adapter) SIM() hal.Field {
	return a.query("AT+CPIN?", func(ls []string) (any, error) {
		p, e := parts(ls, "+CPIN:")
		if e != nil || len(p) != 1 {
			return nil, at.ErrInvalid
		}
		s := strings.TrimSpace(p[0])
		switch s {
		case "READY", "SIM PIN", "SIM PUK", "PH-SIM PIN", "PH-FSIM PIN", "PH-FSIM PUK", "SIM PIN2", "SIM PUK2", "PH-NET PIN", "PH-NET PUK", "PH-NETSUB PIN", "PH-NETSUB PUK", "PH-SP PIN", "PH-SP PUK", "PH-CORP PIN", "PH-CORP PUK":
			return hal.SIM{State: s}, nil
		}
		return nil, at.ErrInvalid
	})
}
func (a *Adapter) Signal() hal.Field {
	return a.query("AT+CSQ", func(ls []string) (any, error) {
		p, e := parts(ls, "+CSQ:")
		if e != nil || len(p) != 2 {
			return nil, at.ErrInvalid
		}
		r, e := number(p[0], 0, 99)
		if e != nil || (r > 31 && r != 99) {
			return nil, at.ErrInvalid
		}
		b, e := number(p[1], 0, 99)
		if e != nil || (b > 7 && b != 99) {
			return nil, at.ErrInvalid
		}
		var dbm *int
		if r != 99 {
			n := -113 + 2*r
			dbm = &n
		}
		return hal.Signal{RSSI: r, BER: b, DBM: dbm}, nil
	})
}
func registration(ls []string, prefix string) (int, error) {
	p, e := parts(ls, prefix)
	if e != nil || len(p) < 2 {
		return 0, at.ErrInvalid
	}
	if _, e = number(p[0], 0, 5); e != nil {
		return 0, e
	}
	return number(p[1], 0, 10)
}
func (a *Adapter) Registration() hal.Field {
	var r hal.Registration
	targets := []**int{&r.CS, &r.Packet, &r.EPS}
	cmds := []string{"AT+CREG?", "AT+CGREG?", "AT+CEREG?"}
	prefix := []string{"+CREG:", "+CGREG:", "+CEREG:"}
	code := "query_failed"
	for i, cmd := range cmds {
		ls, e := a.AT.Query(a.ctx, cmd)
		if e != nil {
			if e == at.ErrDesynchronized {
				code = "at_desynchronized"
			}
			continue
		}
		n, e := registration(ls, prefix[i])
		if e != nil {
			code = "invalid_response"
			continue
		}
		*targets[i] = &n
	}
	if r.CS == nil && r.Packet == nil && r.EPS == nil {
		return hal.Unavailable("at", code)
	}
	return hal.Available("at", r)
}
func (a *Adapter) IMS() hal.Field {
	return a.query("AT+CIREG?", func(ls []string) (any, error) {
		n, e := registration(ls, "+CIREG:")
		if e != nil {
			return nil, e
		}
		return hal.IMS{Registration: n}, nil
	})
}
func (a *Adapter) Calls() hal.Field {
	return a.query("AT+CLCC", func(ls []string) (any, error) {
		s := []int{}
		for _, l := range ls {
			p, e := parts([]string{l}, "+CLCC:")
			if e != nil || len(p) < 5 {
				return nil, at.ErrInvalid
			}
			for i, v := range p[:5] {
				max := 1
				if i == 0 {
					max = 255
				}
				if i == 2 {
					max = 6
				}
				if i == 3 {
					max = 9
				}
				if _, e = number(v, 0, max); e != nil {
					return nil, e
				}
			}
			n, _ := strconv.Atoi(strings.TrimSpace(p[2]))
			s = append(s, n)
		}
		return hal.Calls{Count: len(s), States: s}, nil
	})
}
func (a *Adapter) Network() hal.Field {
	is, e := net.Interfaces()
	if e != nil {
		return hal.Unavailable("linux", "query_failed")
	}
	out := hal.NetworkData{Interfaces: []hal.Interface{}}
	for _, i := range is {
		out.Interfaces = append(out.Interfaces, hal.Interface{Name: i.Name, Up: i.Flags&net.FlagUp != 0, Loopback: i.Flags&net.FlagLoopback != 0})
	}
	return hal.Available("linux", out)
}
func (a *Adapter) Platform() hal.Field {
	b, e := os.ReadFile("/proc/meminfo")
	if e != nil {
		return hal.Unavailable("linux", "query_failed")
	}
	m := map[string]uint64{}
	for _, l := range strings.Split(string(b), "\n") {
		p := strings.Fields(l)
		if len(p) >= 2 {
			n, e := strconv.ParseUint(p[1], 10, 64)
			if e == nil {
				m[p[0]] = n
			}
		}
	}
	total, ok := m["MemTotal:"]
	avail, ok2 := m["MemAvailable:"]
	k, e := os.ReadFile("/proc/sys/kernel/osrelease")
	if !ok || !ok2 || e != nil {
		return hal.Unavailable("linux", "invalid_response")
	}
	return hal.Available("linux", hal.PlatformData{OS: runtime.GOOS, Arch: runtime.GOARCH, Kernel: strings.TrimSpace(string(k)), MemTotal: total, MemAvailable: avail})
}
func (a *Adapter) MessagingCapability() hal.Capability {
	return hal.Capability{Support: "unknown", Readiness: "unavailable", Reason: "not_implemented"}
}
func (a *Adapter) AudioCapability() hal.Capability { return a.MessagingCapability() }
func (a *Adapter) Sample(ctx context.Context) map[string]hal.Field {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	b := a.WithContext(ctx)
	return map[string]hal.Field{"sim": b.SIM(), "signal": b.Signal(), "registration": b.Registration(), "ims": b.IMS(), "calls": b.Calls(), "network": b.Network(), "platform": b.Platform()}
}
