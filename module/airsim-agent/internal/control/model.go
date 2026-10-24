package control

import (
	"airsim.local/airsim-agent/internal/hal"
	"time"
)

type Call struct {
	ID               string    `json:"call_id"`
	State            string    `json:"state"`
	Ownership        string    `json:"ownership"`
	Direction        string    `json:"direction"`
	Number           string    `json:"number"`
	Observed         time.Time `json:"observed_at"`
	DisconnectReason string    `json:"disconnect_reason"`
	object           string
	epoch            string
	born             uint64
}
type Message struct {
	ID        string    `json:"message_id"`
	Direction string    `json:"direction"`
	Sender    string    `json:"sender"`
	Recipient string    `json:"recipient"`
	Text      string    `json:"text"`
	State     string    `json:"state"`
	Delivery  string    `json:"delivery"`
	Observed  time.Time `json:"observed_at"`
	object    string
	epoch     string
	born      uint64
	removed   bool
}
type Status struct {
	Schema     int    `json:"schema_version"`
	Boot       string `json:"agent_boot_id"`
	Epoch      string `json:"backend_epoch"`
	Ready      bool   `json:"ready"`
	Reason     string `json:"reason"`
	Scope      string `json:"scope"`
	VoiceReady bool   `json:"voice_ready"`
	Telephony  bool   `json:"telephony_ready"`
	Messaging  bool   `json:"messaging_ready"`
	InboxGap   bool   `json:"inbox_gap"`
	Dropped    uint64 `json:"inbox_dropped"`
	Remaining  uint64 `json:"command_capacity_remaining"`
}
type CallsView struct {
	Boot      string `json:"agent_boot_id"`
	Epoch     string `json:"backend_epoch"`
	Available bool   `json:"available"`
	Calls     []Call `json:"calls"`
}
type MessagesView struct {
	Boot      string    `json:"agent_boot_id"`
	Epoch     string    `json:"backend_epoch"`
	Available bool      `json:"available"`
	Gap       bool      `json:"inbox_gap"`
	Dropped   uint64    `json:"inbox_dropped"`
	Messages  []Message `json:"messages"`
}

func callState(s string) string {
	switch s {
	case "dialing", "alerting", "incoming", "waiting", "active", "held", "disconnected":
		return s
	}
	return "unknown"
}
func messageState(s string) string {
	switch s {
	case "pending", "queued":
		return "queued"
	case "sent":
		return "sent"
	case "failed":
		return "failed"
	}
	return "unknown"
}

type Session interface {
	hal.ControlBackend
	Close()
}
