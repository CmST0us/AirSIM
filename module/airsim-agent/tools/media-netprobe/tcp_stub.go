//go:build !linux

package main

import "net"

func readTCPInfo(c *net.TCPConn) tcpSample { return tcpSample{} }
