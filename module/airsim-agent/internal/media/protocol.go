package media

import (
	"airsim.local/airsim-agent/internal/control"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"
)

// ASMP v3 carries one 20 ms Opus packet per frame: a 40-byte header followed
// by a payload of the length stated in the header.
const (
	HeaderSize = 40
	// MaxPayload is the largest single Opus packet.
	MaxPayload = 1275
)

// Frame flags. An erasure asks the decoder for packet loss concealment; a FEC
// frame carries the following packet, whose in-band redundancy rebuilds the
// missing one.
const (
	FlagOpus    uint32 = 0
	FlagErasure uint32 = 1
	FlagFEC     uint32 = 2
)

var ErrProtocol = errors.New("media_protocol")

type Frame struct {
	Sequence uint64
	Flags    uint32
	Payload  []byte
}

func ParseSessionID(id string) ([16]byte, error) {
	var out [16]byte
	if !control.ValidID(id) {
		return out, ErrProtocol
	}
	b, e := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	copy(out[:], b)
	return out, e
}
func sessionBytes(id string) ([16]byte, error) { return ParseSessionID(id) }
func validFrame(f Frame) bool {
	switch f.Flags {
	case FlagErasure:
		return len(f.Payload) == 0
	case FlagOpus, FlagFEC:
		return len(f.Payload) > 0 && len(f.Payload) <= MaxPayload
	}
	return false
}

// EncodeInto writes the wire form of f into dst when large enough, avoiding heap allocation.
func (f Frame) EncodeInto(dst []byte, sid [16]byte, direction byte) []byte {
	total := HeaderSize + len(f.Payload)
	var b []byte
	if cap(dst) >= total {
		b = dst[:total]
	} else {
		b = make([]byte, total)
	}
	copy(b[:4], "ASMP")
	b[4] = 3
	b[5] = direction
	binary.LittleEndian.PutUint16(b[6:8], HeaderSize)
	copy(b[8:24], sid[:])
	binary.LittleEndian.PutUint64(b[24:32], f.Sequence)
	binary.LittleEndian.PutUint32(b[32:36], uint32(len(f.Payload)))
	binary.LittleEndian.PutUint32(b[36:40], f.Flags)
	copy(b[HeaderSize:], f.Payload)
	return b
}

// Encode returns the wire form of f for session id and direction.
func (f Frame) Encode(id string, direction byte) []byte {
	sid, _ := sessionBytes(id)
	return f.EncodeInto(nil, sid, direction)
}
func WriteFrameBuf(w io.Writer, sid [16]byte, direction byte, f Frame, scratch []byte) error {
	if !validFrame(f) {
		return ErrProtocol
	}
	return writeAll(w, f.EncodeInto(scratch, sid, direction))
}
func WriteFrame(w io.Writer, id string, direction byte, f Frame) error {
	sid, e := sessionBytes(id)
	if e != nil {
		return ErrProtocol
	}
	var scratch [HeaderSize + MaxPayload]byte
	return WriteFrameBuf(w, sid, direction, f, scratch[:])
}
func ReadFrameBuf(r io.Reader, sid [16]byte, direction byte, last *uint64, payloadBuf []byte) (Frame, uint64, error) {
	var h [HeaderSize]byte
	if _, e := io.ReadFull(r, h[:]); e != nil {
		return Frame{}, 0, e
	}
	n := binary.LittleEndian.Uint32(h[32:36])
	if h[0] != 'A' || h[1] != 'S' || h[2] != 'M' || h[3] != 'P' || h[4] != 3 || h[5] != direction || binary.LittleEndian.Uint16(h[6:8]) != HeaderSize || [16]byte(h[8:24]) != sid || n > MaxPayload {
		return Frame{}, 0, ErrProtocol
	}
	var payload []byte
	if n > 0 {
		if cap(payloadBuf) >= int(n) {
			payload = payloadBuf[:n]
		} else {
			payload = make([]byte, n)
		}
		if _, e := io.ReadFull(r, payload); e != nil {
			return Frame{}, 0, e
		}
	}
	f := Frame{Sequence: binary.LittleEndian.Uint64(h[24:32]), Flags: binary.LittleEndian.Uint32(h[36:40]), Payload: payload}
	if !validFrame(f) || f.Sequence == 0 || f.Sequence <= *last {
		return Frame{}, 0, ErrProtocol
	}
	gap := f.Sequence - *last - 1
	*last = f.Sequence
	return f, gap, nil
}
func ReadFrame(r io.Reader, id string, direction byte, last *uint64) (Frame, uint64, error) {
	sid, e := sessionBytes(id)
	if e != nil {
		var h [HeaderSize]byte
		if _, re := io.ReadFull(r, h[:]); re != nil {
			return Frame{}, 0, re
		}
		return Frame{}, 0, ErrProtocol
	}
	return ReadFrameBuf(r, sid, direction, last, nil)
}
func ReadJSON(r io.Reader, limit uint32) ([]byte, error) {
	var h [4]byte
	if _, e := io.ReadFull(r, h[:]); e != nil {
		return nil, e
	}
	n := binary.LittleEndian.Uint32(h[:])
	if n == 0 || n > limit {
		return nil, ErrProtocol
	}
	b := make([]byte, n)
	_, e := io.ReadFull(r, b)
	return b, e
}
func WriteJSON(w io.Writer, value any, limit uint32) error {
	b, e := json.Marshal(value)
	if e != nil || len(b) == 0 || len(b) > int(limit) {
		return ErrProtocol
	}
	var h [4]byte
	binary.LittleEndian.PutUint32(h[:], uint32(len(b)))
	if e = writeAll(w, h[:]); e != nil {
		return e
	}
	return writeAll(w, b)
}
func writeAll(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, e := w.Write(b)
		if e != nil {
			return e
		}
		if n <= 0 {
			return io.ErrShortWrite
		}
		b = b[n:]
	}
	return nil
}
