package at

import (
	"io"
	"sync"
	"syscall"
	"time"
)

type Device struct {
	mu           sync.Mutex
	fd           int
	closed       chan struct{}
	once         sync.Once
	read         func(int, []byte) (int, error)
	restore      func() error
	TTYSupported bool
	closeErr     error
}

func newDevice(fd int) *Device {
	return &Device{fd: fd, closed: make(chan struct{}), read: syscall.Read}
}
func (d *Device) Close() error {
	d.once.Do(func() {
		close(d.closed)
		d.mu.Lock()
		defer d.mu.Unlock()
		if d.restore != nil {
			d.closeErr = d.restore()
		}
		closeErr := syscall.Close(d.fd)
		if d.closeErr == nil {
			d.closeErr = closeErr
		}
		d.fd = -1
	})
	return d.closeErr
}
func retry(e error) bool {
	return e == syscall.EAGAIN || e == syscall.EWOULDBLOCK || e == syscall.EINTR
}
func (d *Device) wait() error {
	timer := time.NewTimer(10 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-d.closed:
		return io.ErrClosedPipe
	case <-timer.C:
		return nil
	}
}
func (d *Device) Read(b []byte) (int, error) {
	for {
		d.mu.Lock()
		if d.fd < 0 {
			d.mu.Unlock()
			return 0, io.ErrClosedPipe
		}
		n, e := d.read(d.fd, b)
		d.mu.Unlock()
		if retry(e) || (n == 0 && e == nil) {
			if e = d.wait(); e != nil {
				return 0, e
			}
			continue
		}

		return n, e
	}
}
func (d *Device) Write(b []byte) (int, error) {
	for {
		d.mu.Lock()
		if d.fd < 0 {
			d.mu.Unlock()
			return 0, io.ErrClosedPipe
		}
		n, e := syscall.Write(d.fd, b)
		d.mu.Unlock()
		if n <= 0 && retry(e) {
			if e = d.wait(); e != nil {
				return 0, e
			}
			continue
		}
		return n, e
	}
}
