package main

import (
	"context"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

func (a *app) runStream(ctx context.Context, c command, v map[string]string) error {
	if c.Name == "stream urc" || c.Name == "stream nmea" {
		path := a.opts.Device
		if c.Name == "stream nmea" {
			path = v["device"]
		}
		if path == "" {
			return fail(2, "an explicit device is required")
		}
		port, e := openPort(path, a.opts.Baud)
		if e != nil {
			return fail(3, "open stream device: %v", e)
		}
		defer port.Close()
		count := 0
		if v["count"] != "" {
			count, _ = strconv.Atoi(v["count"])
		}
		a.opts.JSON = true
		var pending string
		buf := make([]byte, 4096)
		nlines := 0
		for {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			n, e := port.Read(buf)
			if e != nil && !wouldBlock(e) {
				return e
			}
			pending += string(buf[:n])
			if len(pending) > 1<<20 {
				return fail(3, "line exceeds 1 MiB")
			}
			for {
				line, tail, ok := strings.Cut(pending, "\n")
				if !ok {
					break
				}
				pending = tail
				line = strings.TrimSpace(line)
				if line == "" {
					continue
				}
				if e = a.emit(map[string]any{"time": time.Now().UTC(), "line": line}); e != nil {
					return e
				}
				nlines++
				if count > 0 && nlines >= count {
					return nil
				}
			}
			if n == 0 {
				if e = pause(ctx, 10*time.Millisecond); e != nil {
					return e
				}
			}
		}
	}
	if a.opts.JSON {
		return fail(2, "binary streams cannot use --json; stdout contains only payload bytes")
	}
	d := net.Dialer{Timeout: a.opts.Timeout}
	conn, e := d.DialContext(ctx, "tcp", v["address"])
	if e != nil {
		return fail(3, "stream connect failed: %v", e)
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	if c.Name == "stream pcm" {
		conn.SetDeadline(time.Now().Add(a.opts.Timeout))
		if _, e = io.WriteString(conn, "AIRSIMPCM1\n"); e != nil {
			return e
		}
		ack := make([]byte, len("AIRSIMREADY"))
		if _, e = io.ReadFull(conn, ack); e != nil {
			return e
		}
		if string(ack) != "AIRSIMREADY" {
			return fail(3, "PCM handshake rejected")
		}
		conn.SetDeadline(time.Time{})
	}
	// Input EOF half-closes TCP; the receive side continues until peer EOF/timeout.
	done := make(chan error, 1)
	go func() {
		buf := make([]byte, 32768)
		for {
			n, e := a.in.Read(buf)
			if n > 0 {
				conn.SetWriteDeadline(time.Now().Add(a.opts.Timeout))
				if _, w := conn.Write(buf[:n]); w != nil {
					done <- w
					conn.Close()
					return
				}
			}
			if e != nil {
				if e == io.EOF {
					if tcp, ok := conn.(*net.TCPConn); ok {
						tcp.CloseWrite()
					}
					done <- nil
				} else {
					done <- e
					conn.Close()
				}
				return
			}
		}
	}()
	buf := make([]byte, 32768)
	for {
		conn.SetReadDeadline(time.Now().Add(a.opts.Timeout))
		n, e := conn.Read(buf)
		if n > 0 {
			if _, w := a.out.Write(buf[:n]); w != nil {
				return w
			}
		}
		if e != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			select {
			case w := <-done:
				if w != nil {
					return w
				}
			default:
			}
			if e == io.EOF {
				return nil
			}
			return fail(3, "stream read failed: %v", e)
		}
	}
}
