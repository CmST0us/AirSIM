//go:build !linux

package at

import "syscall"

func configureTTY(fd int) (func() error, bool, error) { return nil, false, syscall.ENOTSUP }
