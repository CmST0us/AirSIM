//go:build linux

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"unsafe"
)

// Use nonblocking syscalls directly: os.File may silently turn a TTY into a
// blocking poll descriptor. Preserve termios and prevent concurrent CLI readers.
type devicePort struct {
	fd   int
	old  *syscall.Termios
	lock *os.File
}

func (p *devicePort) Read(b []byte) (int, error) {
	n, e := syscall.Read(p.fd, b)
	if n < 0 {
		n = 0
	}
	return n, e
}
func (p *devicePort) Write(b []byte) (int, error) {
	n, e := syscall.Write(p.fd, b)
	if n < 0 {
		n = 0
	}
	return n, e
}
func (p *devicePort) Close() error {
	if p.old != nil {
		_, _, _ = syscall.Syscall(syscall.SYS_IOCTL, uintptr(p.fd), syscall.TCSETS, uintptr(unsafe.Pointer(p.old)))
	}
	e := syscall.Close(p.fd)
	_ = syscall.Flock(int(p.lock.Fd()), syscall.LOCK_UN)
	_ = p.lock.Close()
	return e
}
func wouldBlock(e error) bool {
	return errors.Is(e, syscall.EAGAIN) || errors.Is(e, syscall.EWOULDBLOCK) || errors.Is(e, syscall.EINTR)
}
func openPort(path string, baud int) (io.ReadWriteCloser, error) {
	info, e := os.Stat(path)
	if e != nil {
		return nil, e
	}
	if info.Mode()&os.ModeCharDevice == 0 {
		return nil, fmt.Errorf("not a character device")
	}
	// Lock by device identity, so aliases cannot bypass locking. Directory is root-owned.
	st := info.Sys().(*syscall.Stat_t)
	lockPath := filepath.Join("/run/lock", "rm500-"+strconv.FormatUint(uint64(st.Rdev), 10)+".lock")
	fd, e := syscall.Open(lockPath, syscall.O_CREAT|syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0600)
	if e != nil {
		return nil, e
	}
	lock := os.NewFile(uintptr(fd), lockPath)
	if e = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		lock.Close()
		return nil, fmt.Errorf("AT channel is held by another CLI")
	}
	fd, e = syscall.Open(path, syscall.O_RDWR|syscall.O_NONBLOCK|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if e != nil {
		lock.Close()
		return nil, e
	}
	p := &devicePort{fd: fd, lock: lock}
	var old syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCGETS, uintptr(unsafe.Pointer(&old)))
	if errno == 0 {
		speeds := map[int]uint32{9600: syscall.B9600, 19200: syscall.B19200, 38400: syscall.B38400, 57600: syscall.B57600, 115200: syscall.B115200, 230400: syscall.B230400, 460800: syscall.B460800, 921600: syscall.B921600}
		speed, ok := speeds[baud]
		if !ok {
			p.Close()
			return nil, fmt.Errorf("unsupported baud")
		}
		p.old = &old
		t := old
		t.Iflag = 0
		t.Oflag = 0
		t.Lflag = 0
		t.Cflag = syscall.CS8 | syscall.CREAD | syscall.CLOCAL | speed
		t.Cc[syscall.VMIN] = 0
		t.Cc[syscall.VTIME] = 0
		_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&t)))
		if errno != 0 {
			p.Close()
			return nil, errno
		}
	} else if errno != syscall.ENOTTY {
		p.Close()
		return nil, errno
	}
	return p, nil
}
