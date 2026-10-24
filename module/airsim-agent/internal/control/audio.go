package control

import (
	"context"
	"errors"
)

// AudioQualification contains no subscriber or call-number data. Generation
// remembers an intervening invalid state even when notifications coalesce.
type AudioQualification struct {
	Boot       string
	Epoch      string
	CallID     string
	Eligible   bool
	Generation uint64
}

func (c *Coordinator) qualification() AudioQualification {
	q := AudioQualification{Boot: c.boot, Epoch: c.epoch()}
	count := 0
	for _, call := range c.calls {
		if call.epoch == q.Epoch && call.State != "disconnected" {
			count++
			q.CallID = call.ID
			q.Eligible = call.State == "active" && call.Ownership == "managed"
		}
	}
	q.Eligible = q.Eligible && count == 1 && c.status().Ready
	return q
}
func (c *Coordinator) publishAudio() {
	next := c.qualification()
	previous := c.audioLast
	previous.Generation = 0
	if next != previous {
		next.Generation = c.audioLast.Generation + 1
		c.audioLast = next
		select {
		case c.audioEvents <- struct{}{}:
		default:
		}
	}
}
func (c *Coordinator) AudioQualification(ctx context.Context) (AudioQualification, error) {
	v := c.invoke(ctx, apiRequest{kind: "audio_qualification"})
	q, ok := v.Value.(AudioQualification)
	if v.Code != 200 || !ok {
		return AudioQualification{}, errors.New("control_unavailable")
	}
	return q, nil
}
func (c *Coordinator) AudioEvents() <-chan struct{} { return c.audioEvents }
