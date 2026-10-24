package at

import (
	"fmt"
	"os"
	"syscall"
)

func Lock(path string) (*os.File, error) {
	fd, e := syscall.Open(path, syscall.O_CREAT|syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0600)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), path)
	if e = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		f.Close()
		return nil, fmt.Errorf("lock_conflict")
	}
	return f, nil
}
func OpenDevice(path string) (*Device, *os.File, error) {
	if path != "/dev/smd1" {
		return nil, nil, fmt.Errorf("profile_mismatch")
	}
	info, e := os.Lstat(path)
	if e != nil {
		return nil, nil, e
	}
	if info.Mode()&os.ModeCharDevice == 0 {
		return nil, nil, fmt.Errorf("profile_mismatch")
	}
	stat := info.Sys().(*syscall.Stat_t)
	lock, e := Lock(fmt.Sprintf("/run/lock/rm500-%d.lock", stat.Rdev))
	if e != nil {
		return nil, nil, e
	}
	fd, e := syscall.Open(path, syscall.O_RDWR|syscall.O_NONBLOCK|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NOCTTY, 0)
	if e != nil {
		lock.Close()
		return nil, nil, e
	}
	restore, supported, e := configureTTY(fd)
	if e != nil {
		syscall.Close(fd)
		lock.Close()
		return nil, nil, e
	}
	device := newDevice(fd)
	device.restore = restore
	device.TTYSupported = supported
	return device, lock, nil
}
