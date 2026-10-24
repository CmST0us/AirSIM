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

const FrameSize = 360
const PayloadSize = 320

var ErrProtocol = errors.New("media_protocol")

type Frame [FrameSize]byte

func sessionBytes(id string) ([16]byte, error) {
	var out [16]byte
	if !control.ValidID(id) {
		return out, ErrProtocol
	}
	b, e := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	copy(out[:], b)
	return out, e
}
func NewFrame(id string, direction byte, seq uint64) Frame {
	var f Frame
	copy(f[:4], "ASMP")
	f[4] = 1
	f[5] = direction
	binary.LittleEndian.PutUint16(f[6:8], 40)
	b, _ := sessionBytes(id)
	copy(f[8:24], b[:])
	binary.LittleEndian.PutUint64(f[24:32], seq)
	binary.LittleEndian.PutUint32(f[32:36], 320)
	return f
}
func ReadFrame(r io.Reader, id string, direction byte, last *uint64) (Frame, uint64, error) {
	var f Frame
	if _, e := io.ReadFull(r, f[:]); e != nil {
		return f, 0, e
	}
	sid, e := sessionBytes(id)
	if e != nil || string(f[:4]) != "ASMP" || f[4] != 1 || f[5] != direction || binary.LittleEndian.Uint16(f[6:8]) != 40 || string(f[8:24]) != string(sid[:]) || binary.LittleEndian.Uint32(f[32:36]) != 320 || binary.LittleEndian.Uint32(f[36:40]) != 0 {
		return f, 0, ErrProtocol
	}
	seq := binary.LittleEndian.Uint64(f[24:32])
	if seq == 0 || seq <= *last {
		return f, 0, ErrProtocol
	}
	gap := seq - *last - 1
	*last = seq
	return f, gap, nil
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
