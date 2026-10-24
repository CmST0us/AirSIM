//go:build linux

package at

import (
	"syscall"
	"unsafe"
)

func configureTTY(fd int) (func() error, bool, error) {
	var original syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(syscall.TCGETS), uintptr(unsafe.Pointer(&original)))
	if errno == syscall.ENOTTY {
		return nil, false, nil
	}
	if errno != 0 {
		return nil, false, errno
	}
	raw := original
	raw.Iflag = 0
	raw.Oflag = 0
	raw.Lflag = 0
	raw.Cflag = syscall.CS8 | syscall.CREAD | syscall.CLOCAL | syscall.B115200
	raw.Ispeed = syscall.B115200
	raw.Ospeed = syscall.B115200
	raw.Cc[syscall.VMIN] = 0
	raw.Cc[syscall.VTIME] = 0
	_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(syscall.TCSETS), uintptr(unsafe.Pointer(&raw)))
	if errno != 0 {
		return nil, true, errno
	}
	return func() error {
		_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(syscall.TCSETS), uintptr(unsafe.Pointer(&original)))
		if errno != 0 {
			return errno
		}
		var restored syscall.Termios
		_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(syscall.TCGETS), uintptr(unsafe.Pointer(&restored)))
		if errno != 0 {
			return errno
		}
		if restored != original {
			return syscall.EIO
		}
		return nil
	}, true, nil
}
