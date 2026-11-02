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
	"github.com/warthog618/sms/encoding/ucs2"
	"strconv"
	"strings"
	"time"
)

type receivedSMS struct {
	key, sender, text string
	indices           []int
	receivedAt        time.Time
}

func decodeSMS(lines []string) ([]receivedSMS, error) {
	collector := sms.NewCollector()
	defer collector.Close()
	var out []receivedSMS
	indices := map[string][]int{}
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
		index, err := strconv.Atoi(strings.TrimSpace(fields[0]))
		if err != nil || index < 0 || index > 65535 {
			return nil, at.ErrInvalid
		}
		data, err := hex.DecodeString(lines[i+1])
		if err != nil || len(data) < 2 {
			return nil, at.ErrInvalid
		}
		// The AT framing is intact; a stored PDU the decoder cannot read is
		// skipped so one message does not invalidate the control session.
		offset := int(data[0]) + 1
		if offset >= len(data) {
			continue
		}
		p, err := sms.Unmarshal(data[offset:])
		if err != nil || p.SmsType() != tpdu.SmsDeliver {
			continue
		}
		raw, err := p.MarshalBinary()
		if err != nil {
			continue
		}
		partKey := hex.EncodeToString(raw)
		indices[partKey] = append(indices[partKey], index)
		message, ok := decodeDeliver(collector, p)
		if !ok {
			continue
		}
		out = append(out, message)
	}
	for i := range out {
		for _, part := range strings.Split(strings.TrimSuffix(out[i].key, ":"), ":") {
			out[i].indices = append(out[i].indices, indices[part]...)
		}
	}
	return out, nil
}

func decodeDeliver(collector *sms.Collector, p *tpdu.TPDU) (receivedSMS, bool) {
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
	return receivedSMS{key: key.String(), sender: segments[0].OA.Number(), text: string(body), receivedAt: segments[0].SCTS.Time}, true
}

func (s *Session) refreshSMS(ctx context.Context) error {
	lines, err := s.at.Command(ctx, "AT+CMGL=4", "")
	if err != nil {
		s.diagnostics.recordPoll(0, 0, 0, err)
		return err
	}
	messages, err := decodeSMS(lines)
	if err != nil {
		s.diagnostics.recordPoll(len(lines)/2, 0, 0, err)
		return err
	}
	keys := make([]string, len(messages))
	byKey := make(map[string]receivedSMS, len(messages))
	for i, m := range messages {
		keys[i] = m.key
		byKey[m.key] = m
	}
	fresh := s.sms.Reconcile(keys)
	for _, key := range fresh {
		m := byKey[key]
		s.emit(hal.ControlEvent{Kind: "message.incoming", Sender: m.sender, Text: m.text})
	}
	s.diagnostics.recordPoll(len(lines)/2, len(messages), len(fresh), nil)
	_, cleanupErr := s.reclaimSMS(ctx, messages)
	// Eligibility requires the complete message to survive a prior successful
	// poll. A just-arrived message (including a delayed SMS with an old SCTS)
	// cannot be removed in the same poll that first emits it.
	s.previousSMS = make(map[string]bool, len(keys))
	for _, key := range keys {
		s.previousSMS[key] = true
	}
	s.diagnostics.recordCleanupError(cleanupErr)
	return nil
}

func (s *Session) sendSMS(ctx context.Context, a hal.WriteAction) hal.WriteResult {
	// sms.To treats even an unprefixed number as international. Preserve local
	// and short numbers; only an explicit '+' selects international addressing.
	address := tpdu.NewAddress(tpdu.FromNumber(a.Number))
	if !strings.HasPrefix(a.Number, "+") {
		address.SetTypeOfNumber(tpdu.TonUnknown)
	}
	// With AsUCS2 the library expects already encoded UTF-16BE, not UTF-8.
	parts, err := sms.Encode(ucs2.Encode([]rune(a.Text)), sms.WithTemplateOption(tpdu.WithDA(address)), sms.AsUCS2)
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
