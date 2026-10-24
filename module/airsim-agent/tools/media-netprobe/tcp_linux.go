//go:build linux

package main

import (
	"net"
	"syscall"
	"unsafe"
)

func readTCPInfo(c *net.TCPConn) tcpSample {
	var out tcpSample
	raw, e := c.SyscallConn()
	if e != nil {
		return out
	}
	var info syscall.TCPInfo
	length := uint32(unsafe.Sizeof(info))
	var errno syscall.Errno
	e = raw.Control(func(fd uintptr) {
		_, _, errno = syscall.Syscall6(syscall.SYS_GETSOCKOPT, fd, syscall.IPPROTO_TCP, syscall.TCP_INFO, uintptr(unsafe.Pointer(&info)), uintptr(unsafe.Pointer(&length)), 0)
	})
	if e != nil || errno != 0 {
		return out
	}
	out.Available = true
	// Older kernels may return a shorter structure; omit unsupported fields.
	field := func(offset uintptr, value uint32) *uint32 {
		if uintptr(length) < offset+4 {
			return nil
		}
		return &value
	}
	out.RTT = field(unsafe.Offsetof(info.Rtt), info.Rtt)
	out.RTO = field(unsafe.Offsetof(info.Rto), info.Rto)
	out.SndCwnd = field(unsafe.Offsetof(info.Snd_cwnd), info.Snd_cwnd)
	out.Unacked = field(unsafe.Offsetof(info.Unacked), info.Unacked)
	out.TotalRetrans = field(unsafe.Offsetof(info.Total_retrans), info.Total_retrans)
	return out
}
