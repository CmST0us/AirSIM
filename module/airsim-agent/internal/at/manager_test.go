package at

import (
	"context"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestFragmentsURCAndTermination(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	m := New(a, filepath.Join(t.TempDir(), "inflight"))
	defer m.Close()
	go func() {
		buf := make([]byte, 100)
		b.Read(buf)
		for _, s := range []string{"AT+CSQ\r\nRIN", "G\r\n+CSQ: 20,", "99\r\nNO CARRIER\r\nO", "K\r\n"} {
			b.Write([]byte(s))
		}
	}()
	ls, e := m.Query(context.Background(), "AT+CSQ")
	if e != nil || len(ls) != 1 || ls[0] != "+CSQ: 20,99" {
		t.Fatalf("bad result: %v", e)
	}
	if _, e = os.Stat(m.marker); !os.IsNotExist(e) {
		t.Fatal("marker retained")
	}
	if len(m.events) != 2 {
		t.Fatal("urc not separated")
	}
}
func TestTimeoutFencesLateReply(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	marker := filepath.Join(t.TempDir(), "inflight")
	m := New(a, marker)
	defer m.Close()
	sent := make(chan struct{})
	go func() { buf := make([]byte, 100); b.Read(buf); close(sent) }()
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error)
	go func() { _, e := m.Query(ctx, "AT+CSQ"); result <- e }()
	<-sent
	cancel()
	if <-result == nil {
		t.Fatal("cancel accepted")
	}
	select {
	case <-m.Done():
	case <-time.After(time.Second):
		t.Fatal("did not fence")
	}
	if _, e := os.Stat(marker); e != nil {
		t.Fatal("lost fence")
	}
	if _, e := m.Query(context.Background(), "AT+CLCC"); e != ErrDesynchronized {
		t.Fatal(e)
	}
	if _, e := b.Write([]byte("+CSQ: 31,0\r\nOK\r\n")); e == nil {
		t.Fatal("late reply accepted")
	}
}
func TestResponseLimitsAndUnexpectedLine(t *testing.T) {
	for _, payload := range []string{"unexpected\r\n", strings.Repeat("x", 4097), strings.Repeat("+CLCC: 1,0,0,0,0\r\n", 1100)} {
		t.Run("reject", func(t *testing.T) {
			a, b := net.Pipe()
			defer b.Close()
			m := New(a, filepath.Join(t.TempDir(), "fence"))
			defer m.Close()
			go func() { buf := make([]byte, 50); b.Read(buf); io.WriteString(b, payload) }()
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			if _, e := m.Query(ctx, "AT+CLCC"); e == nil {
				t.Fatal("accepted")
			}
			<-m.Done()
			if _, e := os.Stat(m.marker); e != nil {
				t.Fatal("missing fence")
			}
		})
	}
}
func TestLockConflict(t *testing.T) {
	p := filepath.Join(t.TempDir(), "lock")
	a, e := Lock(p)
	if e != nil {
		t.Fatal(e)
	}
	if b, e := Lock(p); e == nil {
		b.Close()
		t.Fatal("duplicate lock")
	}
	a.Close()
	b, e := Lock(p)
	if e != nil {
		t.Fatal(e)
	}
	b.Close()
}
func TestDeviceNoDataClose(t *testing.T) {
	fds := make([]int, 2)
	if e := syscall.Pipe(fds); e != nil {
		t.Fatal(e)
	}
	defer syscall.Close(fds[1])
	syscall.SetNonblock(fds[0], true)
	d := newDevice(fds[0])
	done := make(chan error)
	go func() { _, e := d.Read(make([]byte, 16)); done <- e }()
	select {
	case <-done:
		t.Fatal("EAGAIN treated as failure")
	case <-time.After(40 * time.Millisecond):
	}
	d.Close()
	select {
	case e := <-done:
		if e == nil {
			t.Fatal("missing close error")
		}
	case <-time.After(time.Second):
		t.Fatal("close blocked")
	}
}
func TestURCOverflowBounded(t *testing.T) {
	m := &Manager{events: make(chan struct{}, 64), overflow: make(chan struct{}, 1)}
	for i := 0; i < 100; i++ {
		m.event()
	}
	if len(m.events) != 64 || len(m.overflow) != 1 {
		t.Fatal("overflow not signaled")
	}
}
func TestBlockedWriteCancels(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	m := New(a, filepath.Join(t.TempDir(), "fence"))
	defer m.Close()
	ctx, c := context.WithTimeout(context.Background(), 600*time.Millisecond)
	defer c()
	m.Query(ctx, "AT+CSQ")
	select {
	case <-m.Done():
	case <-time.After(time.Second):
		t.Fatal("blocked write prevented cancellation")
	}
}

func TestGracefulShutdownDrainsInflight(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	m := New(a, filepath.Join(t.TempDir(), "fence"))
	defer m.Close()
	sent := make(chan struct{})
	finish := make(chan struct{})
	go func() {
		buf := make([]byte, 40)
		b.Read(buf)
		close(sent)
		<-finish
		io.WriteString(b, "+CSQ: 20,0\r\nOK\r\n")
	}()
	result := make(chan error)
	go func() { _, e := m.Query(context.Background(), "AT+CSQ"); result <- e }()
	<-sent
	m.Quiesce()
	if _, e := m.Query(context.Background(), "AT+CLCC"); e == nil {
		t.Fatal("accepted new request during drain")
	}
	close(finish)
	if e := <-result; e != nil {
		t.Fatal(e)
	}
	m.GracefulClose()
	if _, e := os.Stat(m.marker); !os.IsNotExist(e) {
		t.Fatal("normal exit retained fence")
	}
}

func TestDeviceZeroReadWaitsUntilClose(t *testing.T) {
	fds := make([]int, 2)
	if e := syscall.Pipe(fds); e != nil {
		t.Fatal(e)
	}
	defer syscall.Close(fds[1])
	d := newDevice(fds[0])
	d.read = func(int, []byte) (int, error) { return 0, nil }
	done := make(chan error)
	go func() { _, e := d.Read(make([]byte, 1)); done <- e }()
	select {
	case <-done:
		t.Fatal("zero read treated as EOF")
	case <-time.After(40 * time.Millisecond):
	}
	d.Close()
	select {
	case e := <-done:
		if e == nil {
			t.Fatal("missing cancellation")
		}
	case <-time.After(time.Second):
		t.Fatal("close blocked")
	}
}

func TestCloseRestoresTTYExactlyOnce(t *testing.T) {
	fds := make([]int, 2)
	if e := syscall.Pipe(fds); e != nil {
		t.Fatal(e)
	}
	defer syscall.Close(fds[1])
	d := newDevice(fds[0])
	restored := 0
	d.restore = func() error { restored++; return syscall.EIO }
	if e := d.Close(); e != syscall.EIO {
		t.Fatal("restore failure lost")
	}
	if e := d.Close(); e != syscall.EIO || restored != 1 {
		t.Fatal("restore repeated or failure lost")
	}
}

func TestURCFloodDoesNotDesynchronizeQuery(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	m := New(a, filepath.Join(t.TempDir(), "fence"))
	defer m.Close()
	go func() {
		buf := make([]byte, 40)
		b.Read(buf)
		io.WriteString(b, strings.Repeat("RING\r\n", 100)+"+CSQ: 20,0\r\nOK\r\n")
	}()
	ls, e := m.Query(context.Background(), "AT+CSQ")
	if e != nil || len(ls) != 1 {
		t.Fatal("URC flood broke session", e)
	}
	select {
	case <-m.Overflow():
	default:
		t.Fatal("lost URC overflow")
	}
	select {
	case <-m.Done():
		t.Fatal("URC overflow closed session")
	default:
	}
}

func TestFullRequestQueueFailsImmediately(t *testing.T) {
	m := &Manager{queue: make(chan request, 16), done: make(chan struct{}), quiesce: make(chan struct{})}
	for i := 0; i < 16; i++ {
		m.queue <- request{}
	}
	start := time.Now()
	_, e := m.Query(context.Background(), "ATI")
	if e != ErrQuery || time.Since(start) > 100*time.Millisecond {
		t.Fatal("full queue did not reject immediately")
	}
}

func TestExactLineLimitAllowsFollowingDelimiter(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	m := New(a, filepath.Join(t.TempDir(), "fence"))
	defer m.Close()
	go func() {
		buf := make([]byte, 40)
		b.Read(buf)
		io.WriteString(b, strings.Repeat("x", 4096)+"\r\nOK\r\n")
	}()
	ls, e := m.Query(context.Background(), "ATI")
	if e != nil || len(ls) != 1 || len(ls[0]) != 4096 {
		t.Fatal("rejected exact 4096-byte line", e)
	}
}
