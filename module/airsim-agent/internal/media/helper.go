package media

import (
	"airsim.local/airsim-agent/internal/strictjson"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

type PCMConfig struct {
	SampleRate   uint32 `json:"sample_rate"`
	PeriodSize   uint32 `json:"period_size"`
	PeriodCount  uint32 `json:"period_count"`
	BufferFrames uint32 `json:"buffer_frames"`
}
type HelperEvent struct {
	Type               string     `json:"type"`
	Code               string     `json:"code,omitempty"`
	SampleRate         uint32     `json:"sample_rate,omitempty"`
	Channels           uint32     `json:"channels,omitempty"`
	SampleFormat       string     `json:"sample_format,omitempty"`
	FrameSamples       uint32     `json:"frame_samples,omitempty"`
	Capture            *PCMConfig `json:"capture,omitempty"`
	Playback           *PCMConfig `json:"playback,omitempty"`
	CaptureSamples     uint64     `json:"capture_samples,omitempty"`
	PlaybackSamples    uint64     `json:"playback_samples,omitempty"`
	CaptureXRuns       uint64     `json:"capture_xruns,omitempty"`
	PlaybackXRuns      uint64     `json:"playback_xruns,omitempty"`
	CaptureDrops       uint64     `json:"capture_drops,omitempty"`
	PlaybackDrops      uint64     `json:"playback_drops,omitempty"`
	InputDrops         uint64     `json:"input_drops,omitempty"`
	SequenceGaps       uint64     `json:"sequence_gaps,omitempty"`
	SilenceSamples     uint64     `json:"silence_samples,omitempty"`
	QueuePeak          uint64     `json:"queue_peak,omitempty"`
	ElapsedMS          uint64     `json:"elapsed_ms,omitempty"`
	CaptureProgressMS  uint64     `json:"capture_progress_ms,omitempty"`
	PlaybackProgressMS uint64     `json:"playback_progress_ms,omitempty"`
}

func parseHelper(b []byte) (HelperEvent, error) {
	var e HelperEvent
	var typ struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(b, &typ) != nil {
		return e, ErrProtocol
	}
	keys := []string{"type"}
	switch typ.Type {
	case "ready":
		keys = append(keys, "sample_rate", "channels", "sample_format", "frame_samples", "capture", "playback")
	case "stats":
		keys = append(keys, "capture_samples", "playback_samples", "capture_xruns", "playback_xruns", "capture_drops", "playback_drops", "input_drops", "sequence_gaps", "silence_samples", "queue_peak", "elapsed_ms", "capture_progress_ms", "playback_progress_ms")
	case "error":
		keys = append(keys, "code")
	default:
		return e, ErrProtocol
	}
	fields, err := strictjson.Object(b, keys, nil)
	if err != nil || json.Unmarshal(b, &e) != nil {
		return e, ErrProtocol
	}
	if e.Type == "ready" {
		for _, key := range []string{"capture", "playback"} {
			if _, err = strictjson.Object(fields[key], []string{"sample_rate", "period_size", "period_count", "buffer_frames"}, nil); err != nil {
				return e, ErrProtocol
			}
		}
		if e.SampleRate != 8000 || e.Channels != 1 || e.SampleFormat != "s16le" || e.FrameSamples != 160 || e.Capture == nil || e.Playback == nil {
			return e, ErrProtocol
		}
		if e.Capture.SampleRate != 8000 || (e.Playback.SampleRate != 8000 && e.Playback.SampleRate != 16000) {
			return e, ErrProtocol
		}
		for _, p := range []*PCMConfig{e.Capture, e.Playback} {
			if p.PeriodSize != 320 || p.PeriodCount != 2 || p.BufferFrames != 640 {
				return e, ErrProtocol
			}
		}
	}
	if e.Type == "stats" && e.QueuePeak > 2 {
		return e, ErrProtocol
	}
	if e.Type == "error" {
		switch e.Code {
		case "arguments", "ipc", "pcm_open", "pcm_config", "pcm_io", "pcm_stalled", "xrun_budget", "frame_invalid", "control_invalid", "ping_timeout", "parent_lost", "thread_start":
		default:
			return e, ErrProtocol
		}
	}
	return e, nil
}

type helper interface {
	Control() net.Conn
	PCM() net.Conn
	Exited() <-chan error
	Send(string) error
	Stop()
}
type child struct {
	cmd          *exec.Cmd
	control, pcm net.Conn
	exited       chan error
	mu           sync.Mutex
	once         sync.Once
}

func (h *child) Control() net.Conn    { return h.control }
func (h *child) PCM() net.Conn        { return h.pcm }
func (h *child) Exited() <-chan error { return h.exited }
func (h *child) Send(op string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.control.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
	return WriteJSON(h.control, struct {
		Op string `json:"op"`
	}{op}, 2048)
}
func (h *child) Stop() {
	h.once.Do(func() {
		_ = h.Send("stop")
		h.pcm.Close()
		select {
		case <-h.exited:
		case <-time.After(2 * time.Second):
			_ = h.cmd.Process.Kill()
			<-h.exited
		}
		h.control.Close()
	})
}
func socketPair() (net.Conn, *os.File, error) {
	fds, e := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if e != nil {
		return nil, nil, e
	}
	syscall.CloseOnExec(fds[0])
	syscall.CloseOnExec(fds[1])
	a := os.NewFile(uintptr(fds[0]), "audio-parent")
	b := os.NewFile(uintptr(fds[1]), "audio-child")
	conn, e := net.FileConn(a)
	a.Close()
	if e != nil {
		b.Close()
		return nil, nil, e
	}
	return conn, b, nil
}
func checkHelper(path string) error {
	if path == "" {
		return errors.New("helper_unconfigured")
	}
	i, e := os.Lstat(path)
	if e != nil || !i.Mode().IsRegular() || i.Mode().Perm()&0111 == 0 {
		return errors.New("helper_unavailable")
	}
	return nil
}
func startChild(_ context.Context, path, id string) (helper, error) {
	if e := checkHelper(path); e != nil {
		return nil, e
	}
	control, cf, e := socketPair()
	if e != nil {
		return nil, e
	}
	defer cf.Close()
	pcm, pf, e := socketPair()
	if e != nil {
		control.Close()
		return nil, e
	}
	defer pf.Close()
	cmd := exec.Command(path, "--session", id, "--profile", "rm500u-embedded")
	cmd.ExtraFiles = []*os.File{cf, pf}
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	h := &child{cmd: cmd, control: control, pcm: pcm, exited: make(chan error, 1)}
	if e = cmd.Start(); e != nil {
		control.Close()
		pcm.Close()
		return nil, e
	}
	go func() { h.exited <- cmd.Wait(); close(h.exited) }()
	return h, nil
}
