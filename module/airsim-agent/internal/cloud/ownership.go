package cloud

import (
	"airsim.local/airsim-agent/internal/control"
	"context"
	"encoding/json"
	"strings"
)

type commandEntry struct{ client, route string }

type callClaim struct {
	client, route, command, call, boot, epoch string
	seen                                      bool
}

// The Agent arbitrates both network entries before submitting any modem side effect.
func (a *Agent) reserveCommand(ctx context.Context, r control.Request, client, route string) bool {
	a.ownerMu.Lock()
	defer a.ownerMu.Unlock()
	if a.entries == nil {
		a.entries = map[string]commandEntry{}
	}
	if _, ok := a.entries[r.CommandID]; !ok && len(a.entries) >= 1024 {
		return false
	}
	if old, ok := a.entries[r.CommandID]; ok && (old.client != client || old.route != route) {
		return false
	}
	if !strings.HasPrefix(r.Action, "call.") {
		a.entries[r.CommandID] = commandEntry{client, route}
		return true
	}
	if a.claim != nil {
		c := a.claim
		if s, e := a.controlView(ctx); e == nil && (c.boot != s.Boot || c.epoch != s.Epoch) {
			a.claim = nil
		}
		if a.claim != nil && c.call != "" {
			raw, code := a.view(ctx, "calls", "")
			if calls, ok := raw.(control.CallsView); ok && code == 200 {
				live, ended := false, false
				for _, v := range calls.Calls {
					if v.ID == c.call {
						if v.State == "disconnected" {
							ended = true
						} else {
							live = true
						}
					}
				}
				if live {
					c.seen = true
				} else if ended || c.seen {
					a.claim = nil
				}
			}
		}
	}
	if c := a.claim; c != nil {
		if c.client != client || c.route != route {
			return false
		}
		if r.Action == "call.dial" || r.Action == "call.answer" {
			if c.command == r.CommandID {
				a.entries[r.CommandID] = commandEntry{client, route}
				return true
			}
			return false
		}
		if c.call == r.Args.CallID {
			a.entries[r.CommandID] = commandEntry{client, route}
			return true
		}
		return false
	}
	if r.Action == "call.dial" || r.Action == "call.answer" {
		a.claim = &callClaim{client: client, route: route, command: r.CommandID, call: r.Args.CallID, boot: r.BootID, epoch: r.Epoch}
	}
	a.entries[r.CommandID] = commandEntry{client, route}
	return true
}
func (a *Agent) rejectClaim(r control.Request, code int) {
	if code >= 400 && code < 500 {
		a.ownerMu.Lock()
		if a.claim != nil && a.claim.command == r.CommandID {
			a.claim = nil
		}
		a.ownerMu.Unlock()
	}
}
func (a *Agent) updateClaim(r control.Request, state, call string) {
	a.ownerMu.Lock()
	defer a.ownerMu.Unlock()
	if a.claim == nil || a.claim.command != r.CommandID {
		return
	}
	if call != "" {
		a.claim.call = call
	}
	if state == "failed" || state == "rejected" || state == "expired" {
		a.claim = nil
	}
}
func (a *Agent) receiptClaim(r control.Request, v any) {
	b, _ := json.Marshal(v)
	var s struct {
		State string `json:"state"`
		Call  string `json:"call_id"`
	}
	_ = json.Unmarshal(b, &s)
	a.updateClaim(r, s.State, s.Call)
}
