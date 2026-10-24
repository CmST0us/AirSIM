package media

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/identity"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func uid() string { id, _ := identity.UUID(); return id }
func TestFramesStrictAndFragmented(t *testing.T) {
	id := uid()
	f := NewFrame(id, 1, 1)
	var seq uint64
	if _, gap, e := ReadFrame(bytes.NewReader(f[:]), id, 1, &seq); e != nil || gap != 0 {
		t.Fatal(e)
	}
	if _, _, e := ReadFrame(bytes.NewReader(f[:]), id, 1, &seq); e == nil {
		t.Fatal("duplicate")
	}
	for _, index := range []int{0, 4, 5, 6, 8, 32, 36} {
		bad := f
		bad[index] ^= 0x7f
		seq = 0
		if _, _, e := ReadFrame(bytes.NewReader(bad[:]), id, 1, &seq); e == nil {
			t.Fatal("accepted corruption", index)
		}
	}
	f = NewFrame(id, 1, 4)
	seq = 1
	if _, gap, e := ReadFrame(bytes.NewReader(f[:]), id, 1, &seq); e != nil || gap != 2 {
		t.Fatal("gap")
	}
	seq = 0
	if _, _, e := ReadFrame(bytes.NewReader(f[:359]), id, 1, &seq); e == nil {
		t.Fatal("partial")
	}
	a, b := net.Pipe()
	defer a.Close()
	go func() {
		defer b.Close()
		for _, v := range f {
			b.Write([]byte{v})
		}
	}()
	seq = 0
	if _, _, e := ReadFrame(a, id, 1, &seq); e != nil {
		t.Fatal("fragmentation", e)
	}
}
func TestLengthAndHelperValidation(t *testing.T) {
	for _, n := range []uint32{0, 2049, 0xffffffff} {
		var b [4]byte
		binary.LittleEndian.PutUint32(b[:], n)
		if _, e := ReadJSON(bytes.NewReader(b[:]), 2048); e == nil {
			t.Fatal("length")
		}
	}
	if _, e := parseHelper([]byte(`{"type":"error","code":"credential-secret"}`)); e == nil {
		t.Fatal("untrusted error exposed")
	}
	if _, e := parseHelper([]byte(`{"type":"error","code":"pcm_open","code":"pcm_io"}`)); e == nil {
		t.Fatal("duplicate")
	}
	if _, e := parseHelper([]byte(`{"type":"error","code":"pcm_config"}`)); e != nil {
		t.Fatal(e)
	}
}

type fakeQualifier struct {
	mu     sync.Mutex
	q      control.AudioQualification
	events chan struct{}
}

func (q *fakeQualifier) AudioQualification(context.Context) (control.AudioQualification, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.q, nil
}
func (q *fakeQualifier) AudioEvents() <-chan struct{} { return q.events }
func (q *fakeQualifier) revoke() {
	q.mu.Lock()
	q.q.Generation++
	q.q.Eligible = false
	q.mu.Unlock()
	select {
	case q.events <- struct{}{}:
	default:
	}
}

type fakeHelper struct {
	ctrl, pcm, otherCtrl, otherPCM net.Conn
	exit                           chan error
	done                           chan struct{}
	once                           sync.Once
	wg                             sync.WaitGroup
	reads                          atomic.Int32
	stall                          bool
	earlyError                     string
}

func (f *fakeHelper) Control() net.Conn    { return f.ctrl }
func (f *fakeHelper) PCM() net.Conn        { return f.pcm }
func (f *fakeHelper) Exited() <-chan error { return f.exit }
func (f *fakeHelper) Send(string) error    { return nil }
func (f *fakeHelper) Stop() {
	f.once.Do(func() {
		close(f.done)
		f.ctrl.Close()
		f.pcm.Close()
		f.otherCtrl.Close()
		f.otherPCM.Close()
		f.wg.Wait()
		close(f.exit)
	})
}
func readyEvent() HelperEvent {
	return HelperEvent{Type: "ready", SampleRate: 8000, Channels: 1, SampleFormat: "s16le", FrameSamples: 160, Capture: &PCMConfig{8000, 320, 2, 640}, Playback: &PCMConfig{8000, 320, 2, 640}}
}
func launchFake(id string, stall bool, earlyError string, nativeRate ...uint32) *fakeHelper {
	c, cp := net.Pipe()
	p, pp := net.Pipe()
	f := &fakeHelper{ctrl: c, pcm: p, otherCtrl: cp, otherPCM: pp, exit: make(chan error), done: make(chan struct{}), stall: stall, earlyError: earlyError}
	f.wg.Add(3)
	go func() {
		defer f.wg.Done()
		event := readyEvent()
		if len(nativeRate) != 0 {
			event.Playback.SampleRate = nativeRate[0]
		}
		if earlyError != "" {
			event = HelperEvent{Type: "error", Code: earlyError}
		}
		if WriteJSON(cp, event, 2048) != nil {
			return
		}
		tick := time.NewTicker(100 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-f.done:
				return
			case <-tick.C:
				stats := map[string]any{"type": "stats", "capture_samples": 0, "playback_samples": 0, "capture_xruns": 0, "playback_xruns": 0, "capture_drops": 0, "playback_drops": 0, "input_drops": 0, "sequence_gaps": 0, "silence_samples": 0, "queue_peak": 0, "elapsed_ms": 0, "capture_progress_ms": 0, "playback_progress_ms": 0}
				if WriteJSON(cp, stats, 2048) != nil {
					return
				}
			}
		}
	}()
	go func() {
		defer f.wg.Done()
		if stall {
			<-f.done
			return
		}
		var last uint64
		for {
			if _, _, e := ReadFrame(pp, id, 1, &last); e != nil {
				return
			}
			f.reads.Add(1)
		}
	}()
	go func() {
		defer f.wg.Done()
		tick := time.NewTicker(20 * time.Millisecond)
		defer tick.Stop()
		var seq uint64
		for {
			select {
			case <-f.done:
				return
			case <-tick.C:
				seq++
				frame := NewFrame(id, 2, seq)
				if writeAll(pp, frame[:]) != nil {
					return
				}
			}
		}
	}()
	return f
}
func setup(t *testing.T, stall bool, earlyError string) (*Manager, *fakeQualifier, *atomic.Pointer[fakeHelper]) {
	t.Helper()
	q := &fakeQualifier{q: control.AudioQualification{Boot: uid(), Epoch: uid(), CallID: uid(), Eligible: true, Generation: 1}, events: make(chan struct{}, 1)}
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	dir, e := os.MkdirTemp("/tmp", "am-")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	os.Chmod(dir, 0700)
	m := New(q, exe, filepath.Join(dir, "m.sock"))
	var ptr atomic.Pointer[fakeHelper]
	m.start = func(_ context.Context, _ string, id string) (helper, error) {
		f := launchFake(id, stall, earlyError)
		ptr.Store(f)
		return f, nil
	}
	go m.Serve(context.Background())
	until(t, func() bool { return m.View().Available })
	t.Cleanup(m.Close)
	return m, q, &ptr
}
func until(t *testing.T, f func() bool) {
	t.Helper()
	end := time.Now().Add(4 * time.Second)
	for !f() {
		if time.Now().After(end) {
			t.Fatal("timed out")
		}
		time.Sleep(time.Millisecond)
	}
}
func create(t *testing.T, m *Manager, q *fakeQualifier) Created {
	t.Helper()
	qual, _ := q.AudioQualification(context.Background())
	r := Request{uid(), qual.Boot, qual.Epoch, qual.CallID}
	c, code := m.Create(context.Background(), r)
	if code != 201 {
		t.Fatal(code)
	}
	return c
}
func connect(t *testing.T, c Created) net.Conn {
	t.Helper()
	conn, e := net.Dial("unix", c.Socket)
	if e != nil {
		t.Fatal(e)
	}
	conn.SetDeadline(time.Now().Add(time.Second))
	if e = WriteJSON(conn, map[string]string{"session_id": c.ID, "token": c.Token}, 1024); e != nil {
		t.Fatal(e)
	}
	b, e := ReadJSON(conn, 1024)
	if e != nil {
		conn.Close()
		t.Fatal(e)
	}
	var ack struct {
		OK bool `json:"ok"`
	}
	json.Unmarshal(b, &ack)
	if !ack.OK {
		t.Fatal("auth")
	}
	conn.SetDeadline(time.Time{})
	return conn
}
func TestCreateIdempotencyConflictAndClosedHistory(t *testing.T) {
	m, q, _ := setup(t, false, "")
	v, _ := q.AudioQualification(context.Background())
	r := Request{uid(), v.Boot, v.Epoch, v.CallID}
	first, code := m.Create(context.Background(), r)
	if code != 201 {
		t.Fatal(code)
	}
	again, code := m.Create(context.Background(), r)
	if code != 200 || first != again {
		t.Fatal("duplicate changed")
	}
	r.CallID = uid()
	if _, code = m.Create(context.Background(), r); code != 409 {
		t.Fatal("conflict")
	}
	if m.Stop(uid()) != 404 || m.View().Session.State != "awaiting_connection" {
		t.Fatal("wrong session stopped")
	}
	if m.Stop(first.ID) != 204 {
		t.Fatal("stop")
	}
	until(t, func() bool { return m.View().Session.State == "closed" })
	if _, code = m.Create(context.Background(), r); code != 410 {
		t.Fatal("closed replay")
	}
	if m.Stop(first.ID) != 204 {
		t.Fatal("idempotent stop")
	}
	b, _ := json.Marshal(m.View())
	if bytes.Contains(b, []byte(first.Token)) || bytes.Contains(b, []byte("token")) {
		t.Fatal("token leaked")
	}
}
func TestDuplexAndLeaseRevocation(t *testing.T) {
	m, q, ptr := setup(t, false, "")
	c := create(t, m, q)
	conn := connect(t, c)
	defer conn.Close()
	frame := NewFrame(c.ID, 1, 1)
	if e := writeAll(conn, frame[:]); e != nil {
		t.Fatal(e)
	}
	var seq uint64
	conn.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, e := ReadFrame(conn, c.ID, 2, &seq); e != nil {
		t.Fatal(e)
	}
	until(t, func() bool { return ptr.Load().reads.Load() == 1 })
	q.revoke()
	until(t, func() bool { return m.View().Session.State == "closed" })
	if m.View().Session.Reason != "lease_revoked" {
		t.Fatal(m.View())
	}
}
func TestSecondConnectionAndInvalidFrameCannotCrossSession(t *testing.T) {
	m, q, _ := setup(t, false, "")
	c := create(t, m, q)
	conn := connect(t, c)
	defer conn.Close()
	other, e := net.Dial("unix", c.Socket)
	if e != nil {
		t.Fatal(e)
	}
	defer other.Close()
	other.SetDeadline(time.Now().Add(time.Second))
	WriteJSON(other, map[string]string{"session_id": c.ID, "token": c.Token}, 1024)
	if _, e = ReadJSON(other, 1024); e == nil {
		t.Fatal("second token binding")
	}
	bad := NewFrame(uid(), 1, 1)
	writeAll(conn, bad[:])
	until(t, func() bool { return m.View().Session.State == "closed" })
	if m.View().Session.Reason != "media_read" {
		t.Fatal(m.View().Session.Reason)
	}
}
func TestHelperReadyErrorPreserved(t *testing.T) {
	m, q, _ := setup(t, false, "pcm_config")
	c := create(t, m, q)
	conn, _ := net.Dial("unix", c.Socket)
	defer conn.Close()
	WriteJSON(conn, map[string]string{"session_id": c.ID, "token": c.Token}, 1024)
	until(t, func() bool { return m.View().Session.State == "closed" })
	if m.View().Session.Reason != "pcm_config" {
		t.Fatal(m.View().Session.Reason)
	}
}
func TestBlockedPCMWriteClosesSession(t *testing.T) {
	m, q, _ := setup(t, true, "")
	c := create(t, m, q)
	conn := connect(t, c)
	defer conn.Close()
	frame := NewFrame(c.ID, 1, 1)
	writeAll(conn, frame[:])
	until(t, func() bool { return m.View().Session.State == "closed" })
	if m.View().Session.Reason != "media_write" {
		t.Fatal(m.View().Session.Reason)
	}
}
func TestClientEOFAndUplinkTimeout(t *testing.T) {
	for _, eof := range []bool{true, false} {
		t.Run(map[bool]string{true: "eof", false: "timeout"}[eof], func(t *testing.T) {
			m, q, _ := setup(t, false, "")
			c := create(t, m, q)
			conn := connect(t, c)
			defer conn.Close()
			if eof {
				conn.Close()
			} else {
				go io.Copy(io.Discard, conn)
			}
			until(t, func() bool { return m.View().Session.State == "closed" })
			if m.View().Session.Reason != "media_read" {
				t.Fatal(m.View().Session.Reason)
			}
		})
	}
}
func TestOldLeaseAndStrictCreate(t *testing.T) {
	m, q, _ := setup(t, false, "")
	v, _ := q.AudioQualification(context.Background())
	for _, r := range []Request{{uid(), uid(), v.Epoch, v.CallID}, {uid(), v.Boot, uid(), v.CallID}, {uid(), v.Boot, v.Epoch, uid()}} {
		if _, code := m.Create(context.Background(), r); code != 409 {
			t.Fatal("old lease")
		}
	}
	good := Request{uid(), v.Boot, v.Epoch, v.CallID}
	b, _ := json.Marshal(good)
	if _, e := ParseRequest(b); e != nil {
		t.Fatal(e)
	}
	if _, e := ParseRequest(append(b, []byte(`{}`)...)); e == nil {
		t.Fatal("trailing")
	}
}
func TestListenerPreservesOtherFilesAndLiveSocket(t *testing.T) {
	dir, e := os.MkdirTemp("/tmp", "am-")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	os.Chmod(dir, 0700)
	path := filepath.Join(dir, "media.sock")
	os.WriteFile(path, []byte("keep"), 0600)
	if _, _, e := listen(path); e == nil {
		t.Fatal("stole file")
	}
	b, _ := os.ReadFile(path)
	if string(b) != "keep" {
		t.Fatal("changed file")
	}
	os.Remove(path)
	_, cleanup, e := listen(path)
	if e != nil {
		t.Fatal(e)
	}
	defer cleanup()
	if _, _, e = listen(path); e == nil {
		t.Fatal("stole live socket")
	}
}

func TestCreateExpiryAndRevokedHandshake(t *testing.T) {
	m, q, ptr := setup(t, false, "")
	c := create(t, m, q)
	q.mu.Lock()
	q.q.Generation++
	q.q.Eligible = false
	q.mu.Unlock()
	conn, _ := net.Dial("unix", c.Socket)
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(time.Second))
	WriteJSON(conn, map[string]string{"session_id": c.ID, "token": c.Token}, 1024)
	if _, e := ReadJSON(conn, 1024); e == nil {
		t.Fatal("revoked handshake accepted")
	}
	until(t, func() bool { return m.View().Session.State == "closed" })
	if ptr.Load() != nil {
		t.Fatal("helper started without lease")
	}
}
func TestHandshakeSlotsBoundedAndSlowClientsRecover(t *testing.T) {
	m, q, _ := setup(t, false, "")
	c := create(t, m, q)
	slow := []net.Conn{}
	for i := 0; i < 4; i++ {
		conn, e := net.Dial("unix", c.Socket)
		if e != nil {
			t.Fatal(e)
		}
		slow = append(slow, conn)
	}
	time.Sleep(20 * time.Millisecond)
	extra, e := net.Dial("unix", c.Socket)
	if e != nil {
		t.Fatal(e)
	}
	defer extra.Close()
	extra.SetReadDeadline(time.Now().Add(time.Second))
	var b [1]byte
	if _, e = extra.Read(b[:]); e == nil {
		t.Fatal("fifth handshake retained")
	}
	for _, conn := range slow {
		conn.Close()
	}
	time.Sleep(20 * time.Millisecond)
	conn := connect(t, c)
	conn.Close()
	until(t, func() bool { return m.View().Session.State == "closed" })
}
func TestHelperExitAndAgentShutdownReclaim(t *testing.T) {
	m, q, ptr := setup(t, false, "")
	c := create(t, m, q)
	conn := connect(t, c)
	go io.Copy(io.Discard, conn)
	until(t, func() bool { return ptr.Load() != nil })
	ptr.Load().Stop()
	until(t, func() bool { return m.View().Session.State == "closed" })
	conn.Close()
	c = create(t, m, q)
	conn = connect(t, c)
	go io.Copy(io.Discard, conn)
	m.Close()
	conn.Close()
	if m.View().Session.State != "closed" {
		t.Fatal("shutdown retained session")
	}
	if _, e := os.Stat(c.Socket); !os.IsNotExist(e) {
		t.Fatal("socket retained")
	}
}
func TestNoConnectExpiresWithoutHelper(t *testing.T) {
	m, q, ptr := setup(t, false, "")
	c := create(t, m, q)
	time.Sleep(5100 * time.Millisecond)
	until(t, func() bool { return m.View().Session.State == "closed" })
	if m.View().Session.ID != c.ID || m.View().Session.Reason != "connect_timeout" || ptr.Load() != nil {
		t.Fatal("unconnected session opened PCM")
	}
}

// The test binary is also a deliberately nonresponsive native child fixture.
func TestMain(m *testing.M) {
	if os.Getenv("AIRSIM_TEST_CHILD") == "hang" && len(os.Args) > 1 && os.Args[1] == "--session" {
		for {
			time.Sleep(time.Second)
		}
	}
	os.Exit(m.Run())
}
func TestRealChildStopKillsAndReapsAfterTwoSeconds(t *testing.T) {
	t.Setenv("AIRSIM_TEST_CHILD", "hang")
	path, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	h, e := startChild(context.Background(), path, uid())
	if e != nil {
		t.Fatal(e)
	}
	start := time.Now()
	h.Stop()
	elapsed := time.Since(start)
	if elapsed < 2*time.Second || elapsed > 3*time.Second {
		t.Fatalf("kill/reap deadline %v", elapsed)
	}
	select {
	case <-h.Exited():
	default:
		t.Fatal("not reaped")
	}
	h.Stop()
}

func TestRefinedHardwareConfigStrict(t *testing.T) {
	good := readyEvent()
	b, _ := json.Marshal(good)
	if _, e := parseHelper(b); e != nil {
		t.Fatal(e)
	}
	for _, cfg := range []PCMConfig{{8000, 160, 4, 640}, {8000, 320, 4, 1280}, {8000, 320, 2, 1280}} {
		bad := readyEvent()
		bad.Capture = &cfg
		b, _ = json.Marshal(bad)
		if _, e := parseHelper(b); e == nil {
			t.Fatal("accepted unsupported config", cfg)
		}
	}
	if good.FrameSamples != 160 {
		t.Fatal("external frame changed")
	}
}

func TestNativeRatesStrictAndRetained(t *testing.T) {
	for _, rate := range []uint32{8000, 16000} {
		good := readyEvent()
		good.Playback.SampleRate = rate
		b, _ := json.Marshal(good)
		parsed, err := parseHelper(b)
		if err != nil || parsed.Playback.SampleRate != rate || parsed.SampleRate != 8000 || parsed.FrameSamples != 160 {
			t.Fatal("native/external rate", err)
		}
		for _, direction := range []string{"capture", "playback"} {
			for _, value := range []any{nil, 0, 48000, -1, 8000.5, "8000"} {
				var obj map[string]any
				json.Unmarshal(b, &obj)
				obj[direction].(map[string]any)["sample_rate"] = value
				invalid, _ := json.Marshal(obj)
				if _, err := parseHelper(invalid); err == nil {
					t.Fatal("invalid native rate accepted", direction, value)
				}
			}
			var obj map[string]any
			json.Unmarshal(b, &obj)
			delete(obj[direction].(map[string]any), "sample_rate")
			invalid, _ := json.Marshal(obj)
			if _, err := parseHelper(invalid); err == nil {
				t.Fatal("missing native rate accepted")
			}
		}
	}
	bad := readyEvent()
	bad.Capture.SampleRate = 16000
	b, _ := json.Marshal(bad)
	if _, err := parseHelper(b); err == nil {
		t.Fatal("16k capture accepted")
	}
	good := readyEvent()
	b, _ = json.Marshal(good)
	duplicate := bytes.Replace(b, []byte(`"capture":{"sample_rate":8000,`), []byte(`"capture":{"sample_rate":8000,"sample_rate":8000,`), 1)
	if bytes.Equal(b, duplicate) {
		t.Fatal("duplicate fixture")
	}
	if _, err := parseHelper(duplicate); err == nil {
		t.Fatal("duplicate nested rate accepted")
	}
	m, q, _ := setup(t, false, "")
	m.start = func(_ context.Context, _ string, id string) (helper, error) {
		return launchFake(id, false, "", 16000), nil
	}
	c := create(t, m, q)
	conn := connect(t, c)
	defer conn.Close()
	v := m.View()
	if v.Session == nil || v.Session.Actual == nil || v.Session.Actual.Playback.SampleRate != 16000 || v.Session.Actual.Capture.SampleRate != 8000 || v.VoiceReady {
		t.Fatal("native rate not retained", v)
	}
	if format.SampleRate != 8000 || format.FrameSamples != 160 {
		t.Fatal("external format changed")
	}
	encoded, _ := json.Marshal(v)
	if !bytes.Contains(encoded, []byte(`"sample_rate":16000`)) {
		t.Fatal("native rate missing from diagnostics")
	}
}
