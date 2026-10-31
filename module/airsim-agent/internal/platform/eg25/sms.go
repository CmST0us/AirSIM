package eg25

import (
	"airsim.local/airsim-agent/internal/at"
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/identity"
	"context"
	"encoding/csv"
	"encoding/hex"
	"fmt"
	"github.com/warthog618/sms"
	"github.com/warthog618/sms/encoding/tpdu"
	"strconv"
	"strings"
)

type receivedSMS struct{ key, sender, text string }

func decodeSMS(lines []string) ([]receivedSMS, error) {
	collector := sms.NewCollector()
	defer collector.Close()
	var out []receivedSMS
	for i := 0; i < len(lines); i += 2 {
		if i+1 >= len(lines) || !strings.HasPrefix(lines[i], "+CMGL:") {
			return nil, at.ErrInvalid
		}
		fields, err := csv.NewReader(strings.NewReader(strings.TrimSpace(strings.TrimPrefix(lines[i], "+CMGL:")))).Read()
		if err != nil || len(fields) < 4 {
			return nil, at.ErrInvalid
		}
		status, err := strconv.Atoi(strings.TrimSpace(fields[1]))
		if err != nil {
			return nil, at.ErrInvalid
		}
		if status != 0 && status != 1 {
			continue
		}
		data, err := hex.DecodeString(lines[i+1])
		if err != nil || len(data) < 2 {
			return nil, at.ErrInvalid
		}
		// The AT framing is intact; a stored PDU the decoder cannot read is
		// skipped so one message does not invalidate the control session.
		message, ok := decodeDeliver(collector, data)
		if !ok {
			continue
		}
		out = append(out, message)
	}
	return out, nil
}

func decodeDeliver(collector *sms.Collector, data []byte) (receivedSMS, bool) {
	offset := int(data[0]) + 1
	if offset >= len(data) {
		return receivedSMS{}, false
	}
	p, err := sms.Unmarshal(data[offset:])
	if err != nil || p.SmsType() != tpdu.SmsDeliver {
		return receivedSMS{}, false
	}
	segments, err := collector.Collect(*p)
	if err != nil || len(segments) == 0 {
		return receivedSMS{}, false
	}
	body, err := sms.Decode(segments)
	if err != nil {
		return receivedSMS{}, false
	}
	var key strings.Builder
	for _, part := range segments {
		raw, err := part.MarshalBinary()
		if err != nil {
			return receivedSMS{}, false
		}
		key.WriteString(hex.EncodeToString(raw))
		key.WriteByte(':')
	}
	return receivedSMS{key: key.String(), sender: segments[0].OA.Number(), text: string(body)}, true
}

func (s *Session) refreshSMS(ctx context.Context) error {
	lines, err := s.at.Command(ctx, "AT+CMGL=4", "")
	if err != nil {
		return err
	}
	messages, err := decodeSMS(lines)
	if err != nil {
		return err
	}
	keys := make([]string, len(messages))
	byKey := make(map[string]receivedSMS, len(messages))
	for i, m := range messages {
		keys[i] = m.key
		byKey[m.key] = m
	}
	for _, key := range s.sms.Reconcile(keys) {
		m := byKey[key]
		s.emit(hal.ControlEvent{Kind: "message.incoming", Sender: m.sender, Text: m.text})
	}
	return nil
}

func (s *Session) sendSMS(ctx context.Context, a hal.WriteAction) hal.WriteResult {
	parts, err := sms.Encode([]byte(a.Text), sms.To(a.Number), sms.AsUCS2)
	if err != nil || len(parts) != 1 {
		return hal.WriteResult{Failed: true}
	}
	data, err := parts[0].MarshalBinary()
	if err != nil {
		return hal.WriteResult{Failed: true}
	}
	object, err := identity.UUID()
	if err != nil {
		return hal.WriteResult{Failed: true}
	}
	lines, err := s.at.Command(ctx, fmt.Sprintf("AT+CMGS=%d", len(data)), "00"+hex.EncodeToString(data))
	if err != nil {
		return result(err)
	}
	if len(lines) != 1 || !strings.HasPrefix(lines[0], "+CMGS:") {
		return hal.WriteResult{Unknown: true}
	}
	s.emit(hal.ControlEvent{Kind: "message.add", Object: object, State: "sent"})
	return hal.WriteResult{Object: object}
}
