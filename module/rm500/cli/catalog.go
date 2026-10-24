package main

import (
	"encoding/hex"
	"fmt"
	"net"
	"regexp"
	"strconv"
	"strings"
)

type param struct {
	Name        string `json:"name"`
	Type        string `json:"type"`
	Required    bool   `json:"required"`
	Description string `json:"description,omitempty"`
}
type command struct {
	Name        string   `json:"name"`
	Backend     string   `json:"backend"`
	Description string   `json:"description"`
	Mutates     bool     `json:"mutates"`
	Params      []param  `json:"params,omitempty"`
	Steps       []string `json:"at_commands,omitempty"`
	Method      string   `json:"method,omitempty"`
	Path        string   `json:"path,omitempty"`
}

func p(n, t string) param        { return param{Name: n, Type: t, Required: true} }
func optional(n, t string) param { return param{Name: n, Type: t} }
func catalog() []command {
	var out []command
	at := func(n, d string, m bool, steps []string, ps ...param) {
		out = append(out, command{Name: n, Backend: "at", Description: d, Mutates: m, Steps: steps, Params: ps})
	}
	one := func(n, d, s string, m bool, ps ...param) { at(n, d, m, []string{s}, ps...) }
	one("at exec", "Execute one explicit AT command (no transparent data mode)", "{command}", true, p("command", "at"))
	one("at commands", "Ask firmware for its AT command list; may be unsupported", "AT+CLAC", false)
	one("device info", "Manufacturer, model and firmware (no subscriber identifiers)", "ATI", false)
	one("device imei", "Read device IMEI", "AT+CGSN", false)
	one("device functionality", "Read modem functionality", "AT+CFUN?", false)
	one("device set-functionality", "Set RF functionality", "AT+CFUN={mode}", true, p("mode", "enum:0,1,4"))
	one("device reboot", "Reboot modem; disconnects data and calls", "AT+CFUN=1,1", true)
	one("device poweroff", "Request module power-off", "AT+QPOWD=1", true)
	one("device clock", "Read modem clock", "AT+CCLK?", false)
	one("sim status", "Read SIM PIN state", "AT+CPIN?", false)
	one("sim iccid", "Read SIM ICCID", "AT+QCCID", false)
	one("sim imsi", "Read subscriber IMSI", "AT+CIMI", false)
	one("sim number", "Read stored subscriber number", "AT+CNUM", false)
	one("sim unlock", "Submit SIM PIN (attempts are limited by SIM)", `AT+CPIN="{pin}"`, true, p("pin", "digits"))
	one("sim slot", "Read SIM slot", "AT+QUIMSLOT?", false)
	one("sim set-slot", "Switch SIM slot", "AT+QUIMSLOT={slot}", true, p("slot", "enum:1,2"))
	one("sim apdu", "Send hexadecimal APDU through CSIM", `AT+CSIM={length},"{apdu}"`, true, p("apdu", "hex"))
	at("network registration", "Read circuit/LTE/5G registration", false, []string{"AT+CREG?", "AT+CEREG?", "AT+C5GREG?"})
	one("network signal", "Read signal strength", "AT+CSQ", false)
	one("network operator", "Read serving operator", "AT+COPS?", false)
	one("network scan", "Scan operators; use --timeout 180s", "AT+COPS=?", false)
	one("network serving-cell", "Read serving cell details", `AT+QENG="servingcell"`, false)
	one("network neighbour-cells", "Read neighbour cells", `AT+QENG="neighbourcell"`, false)
	one("network mode", "Read preferred RAT", `AT+QNWPREFCFG="mode_pref"`, false)
	one("network set-mode", "Set preferred RAT", `AT+QNWPREFCFG="mode_pref",{mode}`, true, p("mode", "enum:AUTO,LTE,NR5G,LTE:NR5G,WCDMA"))
	one("network bands", "Read selected RAT bands", `AT+QNWPREFCFG="{rat}_band"`, false, p("rat", "enum:lte,nsa_nr5g,nr5g"))
	one("network set-bands", "Set colon-separated band numbers", `AT+QNWPREFCFG="{rat}_band",{bands}`, true, p("rat", "enum:lte,nsa_nr5g,nr5g"), p("bands", "bands"))
	one("data contexts", "List PDP/APN contexts", "AT+CGDCONT?", false)
	one("data set-apn", "Define PDP context (does not configure Linux routing)", `AT+CGDCONT={cid},"{type}","{apn}"`, true, p("cid", "cid"), p("type", "enum:IP,IPV6,IPV4V6"), p("apn", "safe"))
	one("data attached", "Read packet attachment", "AT+CGATT?", false)
	one("data attach", "Attach packet service", "AT+CGATT=1", true)
	one("data detach", "Detach packet service", "AT+CGATT=0", true)
	one("data sessions", "Read PDP activation states", "AT+CGACT?", false)
	one("data activate", "Activate PDP context", "AT+CGACT=1,{cid}", true, p("cid", "cid"))
	one("data deactivate", "Deactivate PDP context", "AT+CGACT=0,{cid}", true, p("cid", "cid"))
	one("data address", "Read PDP addresses", "AT+CGPADDR={cid}", false, p("cid", "cid"))
	one("data details", "Read negotiated context parameters", "AT+CGCONTRDP={cid}", false, p("cid", "cid"))
	one("usb mode", "Read firmware USB networking mode", `AT+QCFG="usbnet"`, false)
	one("usb set-mode", "Set RM500U USB networking: 1 ECM, 2 MBIM, 3 RNDIS, 5 NCM; verify firmware", `AT+QCFG="usbnet",{mode}`, true, p("mode", "enum:1,2,3,5"))
	one("usb configuration", "Read firmware USB function configuration", `AT+QCFG="usbcfg"`, false)
	one("router nat", "Read firmware NAT/call mode", `AT+QCFG="nat"`, false)
	one("router lan", "Read firmware LAN configuration", `AT+QCFG="lanip"`, false)
	one("modem config-get", "Read a named QCFG setting", `AT+QCFG="{key}"`, false, p("key", "safe"))
	one("modem config-list", "List QCFG keys and supported parameter ranges", "AT+QCFG=?", false)
	one("modem config-set", "Write explicit QCFG arguments; firmware-specific", `AT+QCFG="{key}",{value}`, true, p("key", "safe"), p("value", "atvalue"))
	one("calls status", "List active calls", "AT+CLCC", false)
	one("calls dial", "Dial a voice call", "ATD{number};", true, p("number", "phone"))
	one("calls answer", "Answer incoming call", "ATA", true)
	one("calls hangup", "Hang up voice calls", "AT+CHUP", true)
	one("calls reject", "Reject incoming call", "AT+CHUP", true)
	one("calls dtmf", "Send DTMF tone", `AT+VTS="{digit}"`, true, p("digit", "enum:0,1,2,3,4,5,6,7,8,9,*,#,A,B,C,D"))
	one("calls mute", "Set microphone mute", "AT+CMUT={enabled}", true, p("enabled", "enum:0,1"))
	one("calls volume", "Set voice volume; range firmware-specific", "AT+CLVL={level}", true, p("level", "uint"))
	one("calls last-error", "Read extended call failure", "AT+CEER", false)
	one("calls ims", "Read IMS registration; an enabled IMS setting alone does not prove registration", "AT+CIREG?", false)
	one("audio mode", "Read firmware audio mode", "AT+QAUDMOD?", false)
	one("audio set-mode", "Set firmware audio mode (0 handset, 1 headset, 2 speaker)", "AT+QAUDMOD={mode}", true, p("mode", "enum:0,1,2"))
	one("audio usb-voice", "Read firmware voice-to-host state; RM500U firmware-dependent", "AT+QPCMV?", false)
	one("sms storage", "Read SMS storage usage", "AT+CPMS?", false)
	one("sms list", "List SMS as PDU; may mark messages read; restores message format", "", true)
	one("sms read", "Read one SMS as PDU; may mark it read", "", true, p("index", "uint"))
	one("sms send", "Send one UTF-16 SMS (up to 70 code units)", "", true, p("number", "phone"), p("text", "text"))
	one("sms send-pdu", "Send complete SMS-SUBMIT PDU including SMSC octet", "", true, p("pdu", "hex"))
	one("sms delete", "Delete exactly one stored SMS", "AT+CMGD={index}", true, p("index", "uint"))
	one("sms notifications", "Configure storage URCs on this AT channel", "AT+CNMI=2,1,0,0,0", true)
	one("gps status", "Read GNSS state; firmware-dependent", "AT+QGPS?", false)
	one("gps start", "Start GNSS", "AT+QGPS=1", true)
	one("gps stop", "Stop GNSS", "AT+QGPSEND", true)
	one("gps location", "Read GNSS fix in decimal coordinates", "AT+QGPSLOC=2", false)
	one("gps nmea", "Read one NMEA sentence type", `AT+QGPSGNMEA="{sentence}"`, false, p("sentence", "enum:GGA,RMC,GSV,GSA,VTG,GNS"))
	local := func(n, d string, m bool, ps ...param) {
		out = append(out, command{Name: n, Backend: "local", Description: d, Mutates: m, Params: ps})
	}
	local("system info", "OS, architecture, kernel, uptime, memory", false)
	local("system capabilities", "Inventory AT nodes, interfaces, sound nodes and installed tools; no AT commands sent", false)
	local("system power", "Read power-supply and thermal sensors", false)
	local("network interfaces", "Read local network addresses and per-interface counters", false)
	local("network routes", "Read Linux routing table; --family 4 or 6 (default 4)", false, optional("family", "enum:4,6"))
	local("network link-set", "Set Linux link state", true, p("interface", "interface"), p("state", "enum:up,down"))
	local("network address-add", "Add Linux interface address", true, p("interface", "interface"), p("cidr", "cidr"))
	local("network address-delete", "Delete Linux interface address", true, p("interface", "interface"), p("cidr", "cidr"))
	local("network route-replace", "Replace route via gateway", true, p("interface", "interface"), p("destination", "route"), p("gateway", "ip"))
	local("network ping", "Ping through selected interface", false, p("host", "host"), optional("interface", "interface"), optional("count", "positive"))
	local("network dns", "Resolve hostname using local resolver", false, p("host", "host"))
	local("usb status", "Read USB gadget descriptors and functions", false)
	local("audio devices", "Read ALSA PCM and sound device inventory", false)
	local("audio mixer", "Read TinyALSA mixer controls", false)
	local("audio mixer-set", "Set one named mixer control (route-specific)", true, p("control", "text"), p("value", "text"))
	local("audio pcm-info", "Query native PCM constraints", false, p("card", "uint"), p("device", "uint"))
	local("audio play", "Play WAV through existing tinyplay; explicit file only", true, p("file", "text"), p("card", "uint"), p("device", "uint"))
	local("audio probe", "Capture bounded PCM in memory and emit only signal statistics; does not establish a call or select routes", true, p("card", "uint"), p("device", "uint"), p("rate", "enum:8000,16000"), p("seconds", "enum:1,2,3,4,5,6,8,10"))
	local("audio tone", "Play a quiet test tone from memory through an explicitly selected PCM device; no route changes", true, p("card", "uint"), p("device", "uint"), p("rate", "enum:8000,16000"), p("seconds", "enum:1,2,3,4,5"), p("frequency", "enum:440,660,880,1000"))
	local("watch interfaces", "Emit interface statistics as NDJSON", false, optional("count", "positive"), optional("interval", "duration"))
	stream := func(n, d string, ps ...param) {
		out = append(out, command{Name: n, Backend: "stream", Description: d, Mutates: true, Params: ps})
	}
	stream("stream tcp", "Full-duplex TCP stdin/stdout; no implicit audio routing", p("address", "address"))
	stream("stream pcm", "PCM bridge stdin/stdout, AIRSIMPCM1 handshake; requires compatible local bridge", p("address", "address"))
	stream("stream urc", "Listen to AT URCs as NDJSON; occupies the chosen AT channel", optional("count", "positive"))
	stream("stream nmea", "Read NMEA lines from an explicit separate device as NDJSON", p("device", "text"), optional("count", "positive"))
	// Optional compatibility client; native commands above never require this server.
	for _, c := range agentCommands() {
		out = append(out, c)
	}
	return out
}

var safePattern = regexp.MustCompile(`^[A-Za-z0-9_./:-]+$`)
var phonePattern = regexp.MustCompile(`^\+?[0-9*#]{1,32}$`)
var bandsPattern = regexp.MustCompile(`^[0-9]+(:[0-9]+)*$`)

func validateFlags(c command, f map[string]string) (map[string]string, error) {
	if c.Name == "network routes" && f["family"] == "" {
		f["family"] = "4"
	}
	allowed := map[string]param{}
	for _, p := range c.Params {
		allowed[p.Name] = p
	}
	for k := range f {
		if _, ok := allowed[k]; !ok {
			return nil, fail(2, "unknown flag --%s for %s", k, c.Name)
		}
	}
	for _, p := range c.Params {
		s, ok := f[p.Name]
		if !ok {
			if p.Required {
				return nil, fail(2, "missing --%s", p.Name)
			}
			continue
		}
		valid := s != ""
		switch p.Type {
		case "text":
			valid = len(s) > 0
		case "safe", "interface", "host":
			valid = safePattern.MatchString(s) && !strings.HasPrefix(s, "-")
			if p.Type == "interface" {
				valid = valid && !strings.Contains(s, "/") && len(s) <= 15
			}
		case "at":
			valid = strings.HasPrefix(strings.ToUpper(s), "AT") && len(s) <= 4096
		case "atvalue":
			valid = len(s) <= 4096
		case "digits":
			_, e := strconv.ParseUint(s, 10, 64)
			valid = e == nil && len(s) >= 4 && len(s) <= 8
		case "hex":
			_, e := hex.DecodeString(s)
			valid = e == nil && len(s) > 0 && len(s) <= 8192
		case "phone":
			valid = phonePattern.MatchString(s)
		case "bands":
			valid = bandsPattern.MatchString(s)
		case "uint", "positive", "cid":
			n, e := strconv.ParseUint(s, 10, 32)
			valid = e == nil
			if p.Type != "uint" {
				valid = valid && n > 0
			}
			if p.Type == "cid" {
				valid = valid && n <= 16
			}
		case "ip":
			valid = net.ParseIP(s) != nil
		case "cidr":
			_, _, e := net.ParseCIDR(s)
			valid = e == nil
		case "route":
			_, _, e := net.ParseCIDR(s)
			valid = s == "default" || e == nil
		case "address":
			h, port, e := net.SplitHostPort(s)
			n, ee := strconv.Atoi(port)
			valid = e == nil && ee == nil && h != "" && n > 0 && n <= 65535
		case "duration":
			_, e := positiveDuration(s)
			valid = e == nil
		default:
			if strings.HasPrefix(p.Type, "enum:") {
				valid = false
				for _, v := range strings.Split(strings.TrimPrefix(p.Type, "enum:"), ",") {
					valid = valid || s == v
				}
			}
		}
		if p.Type != "text" && strings.ContainsAny(s, "\r\n\x00\x1a") {
			valid = false
		}
		if !valid {
			return nil, fail(2, "invalid --%s (expected %s)", p.Name, p.Type)
		}
	}
	return f, nil
}
func redact(v map[string]string) map[string]string {
	out := map[string]string{}
	for k, s := range v {
		switch k {
		case "pin", "text", "number", "pdu", "apdu", "data", "command", "value":
			s = "[redacted]"
		}
		out[k] = s
	}
	return out
}
func renderAT(s string, v map[string]string) string {
	for k, val := range v {
		s = strings.ReplaceAll(s, "{"+k+"}", val)
	}
	if apdu, ok := v["apdu"]; ok {
		s = strings.ReplaceAll(s, "{length}", fmt.Sprint(len(apdu)))
	}
	return s
}
