package rtc

import (
	"bytes"
	"strings"
	"testing"
)

func TestREDPreservesTwoLostFramesExactly(t *testing.T) {
	for _, ts := range []uint32{100000, 0xfffffc00} {
		a := AudioPacket{Timestamp: ts, Payload: bytes.Repeat([]byte{0x78, 1}, 120)}
		b := AudioPacket{Timestamp: ts + OpusFrameTicks, Payload: bytes.Repeat([]byte{0x78, 2}, 120)}
		c := AudioPacket{Timestamp: ts + 2*OpusFrameTicks, Payload: bytes.Repeat([]byte{0x78, 3}, 120)}
		wire := encodeRED(c, []AudioPacket{a, b}, 111)
		out, e := decodeRED(9, c.Timestamp, wire, 111)
		if e != nil || len(out) != 3 {
			t.Fatalf("decode %v", e)
		}
		for i, w := range []AudioPacket{c, a, b} {
			if out[i].Timestamp != w.Timestamp || !bytes.Equal(out[i].Payload, w.Payload) || out[i].Redundant != (i != 0) {
				t.Fatalf("block %d", i)
			}
		}
		if len(wire) != 729 {
			t.Fatal(len(wire))
		}
	}
}
func TestREDMTUBudgetAndLongTimestampGap(t *testing.T) {
	p := bytes.Repeat([]byte{0x78}, 500)
	a := AudioPacket{Timestamp: 1000, Payload: p}
	b := AudioPacket{Timestamp: 1960, Payload: p}
	c := AudioPacket{Timestamp: 2920, Payload: p}
	wire := encodeRED(c, []AudioPacket{a, b}, 109)
	if len(wire) > redPayloadBudget {
		t.Fatal("MTU budget exceeded")
	}
	out, e := decodeRED(3, c.Timestamp, wire, 109)
	if e != nil || len(out) != 2 || out[1].Timestamp != b.Timestamp {
		t.Fatal("newest redundancy lost", e)
	}
	c.Timestamp = 200000
	out, e = decodeRED(4, c.Timestamp, encodeRED(c, []AudioPacket{a, b}, 109), 109)
	if e != nil || len(out) != 1 {
		t.Fatal("stale history emitted", e)
	}
}
func TestREDRejectsMalformedBlocks(t *testing.T) {
	p := AudioPacket{Timestamp: 960, Payload: []byte{0x78, 1}}
	good := encodeRED(p, []AudioPacket{{Timestamp: 0, Payload: []byte{0x78, 2}}}, 111)
	cases := [][]byte{nil, {0xef}, {0xef, 1, 2}, {111}, {110, 0x78}, good[:5]}
	bad := append([]byte(nil), good...)
	bad[1] = 0
	bad[2] = 0
	cases = append(cases, bad)
	bad = append([]byte(nil), good...)
	bad[3] = 255
	cases = append(cases, bad)
	for i, p := range cases {
		if _, e := decodeRED(1, 960, p, 111); e == nil {
			t.Fatalf("case %d accepted", i)
		}
	}
}
func TestOpus20msDurationGate(t *testing.T) {
	for _, p := range [][]byte{{0x78}, {0xf8, 0xff, 0xfe}, {0x48}, {0xf1}, {0x83, 8}} {
		if !opus20ms(p) {
			t.Fatalf("valid duration %v", p)
		}
	}
	for _, p := range [][]byte{nil, {0}, {0x10}, {0x18}, {0x79}, {0x7b}, {0x7b, 0}, {0x7b, 3}} {
		if opus20ms(p) {
			t.Fatalf("invalid duration %v", p)
		}
	}
}
func FuzzDecodeRED(f *testing.F) {
	f.Add([]byte{111, 0x78, 0x01})
	f.Add([]byte{239, 15, 0, 2, 111, 0x78, 1, 0x78, 2})
	f.Fuzz(func(t *testing.T, p []byte) {
		out, e := decodeRED(0, 0, p, 111)
		if e != nil {
			return
		}
		if len(out) > 10 {
			t.Fatal("unbounded blocks")
		}
		for _, b := range out {
			if !opus20ms(b.Payload) {
				t.Fatal("invalid block")
			}
		}
	})
}

func TestAudioCodecNegotiation(t *testing.T) {
	for _, tc := range []struct {
		name, formats, attributes string
		red                       bool
	}{
		{"dynamic_payloads", "109 63", "a=rtpmap:109 opus/48000/2\r\na=rtpmap:63 red/48000/2\r\na=fmtp:63 109/109", true},
		{"unmatched_inner_codec", "109 63", "a=rtpmap:109 opus/48000/2\r\na=rtpmap:63 red/48000/2\r\na=fmtp:63 111/111", false},
		{"not_offered", "109", "a=rtpmap:109 opus/48000/2\r\na=rtpmap:63 red/48000/2\r\na=fmtp:63 109/109", false},
		{"wrong_clock", "109 63", "a=rtpmap:109 opus/48000/2\r\na=rtpmap:63 red/8000/1\r\na=fmtp:63 109/109", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			offer := strings.Join([]string{"v=0", "o=- 0 0 IN IP4 127.0.0.1", "s=-", "t=0 0", "m=audio 9 UDP/TLS/RTP/SAVPF " + tc.formats, tc.attributes, ""}, "\r\n")
			c, e := offeredAudioCodecs(offer)
			if e != nil || c.opus != 109 || c.hasRED != tc.red {
				t.Fatal("codec mapping", c, e)
			}
		})
	}
}
