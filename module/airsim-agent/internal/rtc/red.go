package rtc

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/pion/sdp/v3"
	"github.com/pion/webrtc/v4"
)

const (
	OpusClock        = 48000
	OpusFrameTicks   = 960
	redDepth         = 2
	redPayloadBudget = 1200
	maxOpusPacket    = 1275
)

var ErrAudioPacket = errors.New("rtc_audio_packet_invalid")

// AudioPacket is a media-time unit, not a network arrival. Redundant packets
// retain their original timestamp; they must never advance the playout clock.
type AudioPacket struct {
	Sequence  uint16
	Timestamp uint32
	Payload   []byte
	Redundant bool
}

type audioCodecs struct {
	opus, red uint8
	hasRED    bool
}

func offeredAudioCodecs(offer string) (audioCodecs, error) {
	var description sdp.SessionDescription
	if description.Unmarshal([]byte(offer)) != nil {
		return audioCodecs{}, ErrRejected
	}
	for _, m := range description.MediaDescriptions {
		if m.MediaName.Media != "audio" {
			continue
		}
		var c audioCodecs
		found := false
		redTypes := map[uint8]bool{}
		formats := map[string]bool{}
		for _, f := range m.MediaName.Formats {
			formats[f] = true
		}
		for _, a := range m.Attributes {
			if a.Key != "rtpmap" {
				continue
			}
			parts := strings.Fields(a.Value)
			if len(parts) != 2 || !formats[parts[0]] {
				continue
			}
			pt, err := strconv.ParseUint(parts[0], 10, 7)
			if err != nil {
				continue
			}
			switch strings.ToLower(parts[1]) {
			case "opus/48000/2":
				if !found {
					c.opus = uint8(pt)
					found = true
				}
			case "red/48000/2":
				redTypes[uint8(pt)] = true
			}
		}
		if !found {
			return c, ErrRejected
		}
		for _, a := range m.Attributes {
			if a.Key != "fmtp" {
				continue
			}
			parts := strings.Fields(a.Value)
			if len(parts) != 2 {
				continue
			}
			pt, err := strconv.ParseUint(parts[0], 10, 7)
			if err != nil || !redTypes[uint8(pt)] {
				continue
			}
			valid := true
			for _, block := range strings.Split(parts[1], "/") {
				if block != strconv.Itoa(int(c.opus)) {
					valid = false
				}
			}
			if valid {
				c.red = uint8(pt)
				c.hasRED = true
				break
			}
		}
		return c, nil
	}
	return audioCodecs{}, ErrRejected
}

// opus20ms validates the duration described by the Opus TOC (RFC 6716).
// The codec still validates the bitstream itself. Never stretch a 10/40/60 ms
// packet into one 20 ms hardware period by silently concealing it.
func opus20ms(p []byte) bool {
	if len(p) == 0 || len(p) > maxOpusPacket {
		return false
	}
	config := p[0] >> 3
	var ticks int
	switch {
	case config >= 16:
		ticks = 120 << (config & 3)
	case config >= 12:
		ticks = 480 << (config & 1)
	default:
		ticks = 480 << (config & 3)
		if config&3 == 3 {
			ticks = 2880
		}
	}
	frames := 1
	switch p[0] & 3 {
	case 1, 2:
		frames = 2
	case 3:
		if len(p) < 2 {
			return false
		}
		frames = int(p[1] & 63)
	}
	return ticks*frames == OpusFrameTicks
}

// encodeRED sends exact copies of up to two previous Opus packets (RFC 2198).
// Older redundancy is removed first to bound the datagram size. No re-encoding
// or retransmission round trip is needed, and originals remain byte-identical.
func encodeRED(primary AudioPacket, history []AudioPacket, pt uint8) []byte {
	selected := make([]AudioPacket, 0, redDepth)
	size := 1 + len(primary.Payload)
	for i := len(history) - 1; i >= 0 && len(selected) < redDepth; i-- {
		old := history[i]
		offset := primary.Timestamp - old.Timestamp
		if offset == 0 || offset >= 1<<14 || len(old.Payload) > 1023 || size+4+len(old.Payload) > redPayloadBudget {
			break
		}
		selected = append(selected, old)
		size += 4 + len(old.Payload)
	}
	out := make([]byte, 0, size)
	for i := len(selected) - 1; i >= 0; i-- {
		old := selected[i]
		delta := primary.Timestamp - old.Timestamp
		n := len(old.Payload)
		out = append(out, pt|0x80, byte(delta>>6), byte(delta<<2)|byte(n>>8), byte(n))
	}
	out = append(out, pt)
	for i := len(selected) - 1; i >= 0; i-- {
		out = append(out, selected[i].Payload...)
	}
	return append(out, primary.Payload...)
}

// decodeRED validates the entire packet before exposing any block. Primary
// comes first so startup is anchored to live audio rather than old redundancy.
func decodeRED(seq uint16, timestamp uint32, payload []byte, pt uint8) ([]AudioPacket, error) {
	type block struct {
		offset uint32
		size   int
	}
	blocks := make([]block, 0, redDepth)
	pos := 0
	for {
		if pos >= len(payload) || payload[pos]&0x7f != pt {
			return nil, ErrAudioPacket
		}
		if payload[pos]&0x80 == 0 {
			pos++
			break
		}
		// Accept the maximum negotiated WebRTC redundancy depth, even though we
		// currently send two. Bound all memory and work for authenticated bad input.
		if len(blocks) >= 9 || pos+4 > len(payload) {
			return nil, ErrAudioPacket
		}
		b := block{uint32(payload[pos+1])<<6 | uint32(payload[pos+2]>>2), int(payload[pos+2]&3)<<8 | int(payload[pos+3])}
		if b.offset == 0 || b.offset%OpusFrameTicks != 0 || b.size == 0 {
			return nil, ErrAudioPacket
		}
		blocks = append(blocks, b)
		pos += 4
	}
	start := pos
	for _, b := range blocks {
		pos += b.size
		if pos >= len(payload) {
			return nil, ErrAudioPacket
		}
	}
	primary := payload[pos:]
	if !opus20ms(primary) {
		return nil, ErrAudioPacket
	}
	out := []AudioPacket{{Sequence: seq, Timestamp: timestamp, Payload: primary}}
	pos = start
	for _, b := range blocks {
		p := payload[pos : pos+b.size]
		pos += b.size
		if !opus20ms(p) {
			return nil, ErrAudioPacket
		}
		out = append(out, AudioPacket{Timestamp: timestamp - b.offset, Payload: p, Redundant: true})
	}
	return out, nil
}

// RED first asks libwebrtc to use redundancy in both directions. Opus remains
// negotiated as RED's inner codec, and as a fallback for peers without RED.
func (c audioCodecs) parameters() []webrtc.RTPCodecParameters {
	opus := webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: OpusClock, Channels: 2, SDPFmtpLine: opusFmtp}, PayloadType: webrtc.PayloadType(c.opus)}
	if !c.hasRED {
		return []webrtc.RTPCodecParameters{opus}
	}
	red := webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: "audio/red", ClockRate: OpusClock, Channels: 2, SDPFmtpLine: fmt.Sprintf("%d/%d", c.opus, c.opus)}, PayloadType: webrtc.PayloadType(c.red)}
	return []webrtc.RTPCodecParameters{red, opus}
}
