package cloud

import (
	"time"

	"airsim.local/airsim-agent/internal/state"
)

func (a *Agent) signalView() state.SignalView {
	if a.Signal == nil {
		return state.SignalView{}
	}
	return a.Signal.Signal(time.Now())
}
