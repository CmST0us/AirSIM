//go:build !linux

package main

import "io"

func openPort(_ string, _ int) (io.ReadWriteCloser, error) {
	return nil, fail(3, "native AT devices require Linux; cross-build and run inside the module")
}
func wouldBlock(_ error) bool { return false }
