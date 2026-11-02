package eg25

import (
	"airsim.local/airsim-agent/internal/at"
	"airsim.local/airsim-agent/internal/hal"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"github.com/warthog618/sms"
	"github.com/warthog618/sms/encoding/tpdu"
	"strings"
	"testing"
)

type smsCapturePort struct {
	command, payload string
	writes           int
	err              error
}

func (p *smsCapturePort) Query(context.Context, string) ([]string, error) { return nil, at.ErrInvalid }
func (p *smsCapturePort) Done() <-chan struct{}                           { return nil }
func (p *smsCapturePort) Command(_ context.Context, command, payload string) ([]string, error) {
	p.command, p.payload = command, payload
	p.writes++
	if p.err != nil {
		return nil, p.err
	}
	return []string{"+CMGS: 42"}, nil
}

func smsTestSession(p *smsCapturePort) *Session {
	return &Session{at: p, events: make(chan hal.ControlEvent, 1), overflow: make(chan struct{}, 1)}
}

func TestSendSMSAddressAndTextOnWire(t *testing.T) {
	for _, number := range []string{"123456", "012345", "1234567", "12025550123", "+12025550123"} {
		for _, body := range []struct{ name, text, hex string }{
			{"one_digit", "1", "0031"},
			{"even_ascii", "AB", "00410042"},
			{"chinese", "你好", "4f60597d"},
			{"emoji", "😀", "d83dde00"},
			{"max_chinese", strings.Repeat("你", 70), strings.Repeat("4f60", 70)},
			{"max_emoji", strings.Repeat("😀", 35), strings.Repeat("d83dde00", 35)},
		} {
			t.Run(number+"/"+body.name, func(t *testing.T) {
				port := &smsCapturePort{}
				s := smsTestSession(port)
				result := s.Execute(context.Background(), hal.WriteAction{Action: "sms.send", Number: number, Text: body.text})
				if result.Failed || result.Unknown || result.Object == "" || port.writes != 1 {
					t.Fatalf("send rejected or duplicated: %+v, writes=%d", result, port.writes)
				}
				wire, err := hex.DecodeString(port.payload)
				if err != nil || len(wire) < 2 || wire[0] != 0 {
					t.Fatal("invalid PDU-mode SMSC framing")
				}
				if port.command != fmt.Sprintf("AT+CMGS=%d", len(wire)-1) {
					t.Fatal("CMGS length must exclude the SMSC prefix")
				}
				pdu, err := sms.Unmarshal(wire[1:], sms.AsMO)
				if err != nil || pdu.SmsType() != tpdu.SmsSubmit {
					t.Fatalf("invalid SMS-SUBMIT: %v", err)
				}
				toa := byte(0x81)
				if strings.HasPrefix(number, "+") {
					toa = 0x91
				}
				if pdu.DA.TOA != toa || pdu.DA.Number() != number {
					t.Errorf("recipient changed: TOA=%02x, number=%q", pdu.DA.TOA, pdu.DA.Number())
				}
				if pdu.DCS != tpdu.DcsUCS2Data || hex.EncodeToString(pdu.UD) != body.hex || len(pdu.UDH) != 0 {
					t.Errorf("incorrect UCS-2 user data: %x", pdu.UD)
				}
				decoded, err := sms.Decode([]*tpdu.TPDU{pdu})
				if err != nil || string(decoded) != body.text {
					t.Errorf("SMS text did not round trip: %v", err)
				}
				event := <-s.events
				if event.Kind != "message.add" || event.State != "sent" || event.Object != result.Object {
					t.Fatal("missing accepted send event")
				}
			})
		}
	}
}

func TestSendSMSRejectsMultipartBeforeWriting(t *testing.T) {
	for _, body := range []string{strings.Repeat("A", 71), strings.Repeat("你", 71), strings.Repeat("😀", 36)} {
		port := &smsCapturePort{}
		result := smsTestSession(port).Execute(context.Background(), hal.WriteAction{Action: "sms.send", Number: "123456", Text: body})
		if !result.Failed || port.writes != 0 {
			t.Fatal("oversize SMS reached the modem")
		}
	}
}

func TestSendSMSFailureDoesNotRetryOrReportSent(t *testing.T) {
	for _, err := range []error{at.ErrQuery, errors.New("connection_lost")} {
		port := &smsCapturePort{err: err}
		s := smsTestSession(port)
		result := s.Execute(context.Background(), hal.WriteAction{Action: "sms.send", Number: "123456", Text: "AB"})
		if port.writes != 1 || len(s.events) != 0 || result.Object != "" || result.Failed != errors.Is(err, at.ErrQuery) || result.Unknown != !errors.Is(err, at.ErrQuery) {
			t.Fatal("failure retried or misreported")
		}
	}
}

func TestIncomingPDUAndMultipart(t *testing.T) {
	for _, body := range []string{"hello @ world", "你好，模块", strings.Repeat("中文消息", 40)} {
		parts, err := sms.Encode([]byte(body), sms.AsDeliver, sms.From("+12345678901"))
		if err != nil {
			t.Fatal(err)
		}
		var lines []string
		for i, p := range parts {
			b, err := p.MarshalBinary()
			if err != nil {
				t.Fatal(err)
			}
			lines = append(lines, fmt.Sprintf("+CMGL: %d,0,,%d", i+1, len(b)), "00"+hex.EncodeToString(b))
		}
		got, err := decodeSMS(lines)
		if err != nil || len(got) != 1 || got[0].text != body || got[0].sender != "+12345678901" {
			t.Fatalf("decode failed: %v", err)
		}
	}
	if got, err := decodeSMS([]string{"+CMGL: 1,0,,7", "FF00"}); err != nil || len(got) != 0 {
		t.Fatal("truncated SMSC must be skipped without failing the list")
	}
	parts, err := sms.Encode([]byte("after"), sms.AsDeliver, sms.From("+12345678901"))
	if err != nil {
		t.Fatal(err)
	}
	b, err := parts[0].MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	got, err := decodeSMS([]string{"+CMGL: 1,0,,3", "000400", "+CMGL: 2,0,,1", "00" + hex.EncodeToString(b)})
	if err != nil || len(got) != 1 || got[0].text != "after" {
		t.Fatalf("undecodable PDU blocked later messages: %v", err)
	}
	if _, err := decodeSMS([]string{"+CMGL: 1,0,,1", "zz"}); err == nil {
		t.Fatal("accepted non-hex PDU line")
	}
}
