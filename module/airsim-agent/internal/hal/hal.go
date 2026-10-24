package hal

import "time"

type Capability struct {
	Support   string `json:"support"`
	Readiness string `json:"readiness"`
	Reason    string `json:"reason"`
}
type Field struct {
	Status     string     `json:"status"`
	ObservedAt *time.Time `json:"observed_at"`
	Source     string     `json:"source"`
	ErrorCode  string     `json:"error_code"`
	Data       any        `json:"data"`
}
type SIM struct {
	State string `json:"state"`
}
type Signal struct {
	RSSI int  `json:"rssi"`
	BER  int  `json:"ber"`
	DBM  *int `json:"dbm"`
}
type Registration struct {
	CS     *int `json:"cs"`
	Packet *int `json:"packet"`
	EPS    *int `json:"eps"`
}
type IMS struct {
	Registration int `json:"registration"`
}
type Calls struct {
	Count  int   `json:"count"`
	States []int `json:"states"`
}
type Interface struct {
	Name     string `json:"name"`
	Up       bool   `json:"up"`
	Loopback bool   `json:"loopback"`
}
type NetworkData struct {
	Interfaces []Interface `json:"interfaces"`
}
type PlatformData struct {
	OS           string `json:"os"`
	Arch         string `json:"arch"`
	Kernel       string `json:"kernel"`
	MemTotal     uint64 `json:"mem_total_kib"`
	MemAvailable uint64 `json:"mem_available_kib"`
}

// R1 exposes only read-side contracts. Write operations are intentionally absent.
type Telephony interface{ Calls() Field }
type RadioSIM interface {
	SIM() Field
	Signal() Field
	Registration() Field
	IMS() Field
}
type Messaging interface{ MessagingCapability() Capability }
type Audio interface{ AudioCapability() Capability }
type Network interface{ Network() Field }
type Platform interface{ Platform() Field }

func Available(source string, data any) Field {
	now := time.Now()
	return Field{"available", &now, source, "", data}
}
func Unavailable(source, code string) Field {
	return Field{Status: "unavailable", Source: source, ErrorCode: code}
}
