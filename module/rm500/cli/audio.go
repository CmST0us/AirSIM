package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// TinyALSA is already part of the device firmware. PCM stays in anonymous
// pipes and bounded memory, never in a named recording or diagnostic output.
func (a *app) runAudio(ctx context.Context, name string, v map[string]string) error {
	if runtime.GOOS != "linux" {
		return fail(5, "native audio requires the RM500 Linux system")
	}
	rate, _ := strconv.Atoi(v["rate"])
	seconds, _ := strconv.Atoi(v["seconds"])
	if a.opts.Timeout < time.Duration(seconds+2)*time.Second {
		return fail(2, "--timeout must allow at least seconds + 2 seconds")
	}
	ctx, cancel := context.WithTimeout(ctx, a.opts.Timeout)
	defer cancel()
	if name == "audio tone" {
		frequency, _ := strconv.Atoi(v["frequency"])
		wav := toneWAV(rate, seconds, frequency)
		cmd := exec.CommandContext(ctx, "tinyplay", "/proc/self/fd/0", "-D", v["card"], "-d", v["device"], "-p", strconv.Itoa(rate/50), "-n", "4")
		cmd.Stdin = bytes.NewReader(wav)
		out, err := cmd.CombinedOutput()
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil || audioToolFailed(string(out)) {
			return fail(5, "tinyplay failed: %v: %s", err, strings.TrimSpace(string(out)))
		}
		return a.emit(map[string]any{"rate": rate, "seconds": seconds, "frequency": frequency, "amplitude_dbfs": -24, "pcm_bytes": len(wav) - 44, "note": "PCM submitted; the remote listener must confirm audibility"})
	}
	r, w, err := os.Pipe()
	if err != nil {
		return err
	}
	defer r.Close()
	defer w.Close()
	cmd := exec.CommandContext(ctx, "tinycap", "/proc/self/fd/3", "-D", v["card"], "-d", v["device"], "-c", "1", "-r", v["rate"], "-b", "16", "-p", strconv.Itoa(rate/50), "-n", "4", "-T", v["seconds"])
	cmd.ExtraFiles = []*os.File{w}
	var diagnostic bytes.Buffer
	cmd.Stdout, cmd.Stderr = &diagnostic, &diagnostic
	if err = cmd.Start(); err != nil {
		return fail(5, "start tinycap: %v", err)
	}
	w.Close()
	// Allow bounded buffering overhead; a firmware's -T implementation may
	// return more PCM than requested. Report both durations without guessing why.
	limit := (seconds+2)*rate*2 + 88
	started := time.Now()
	b, readErr := io.ReadAll(io.LimitReader(r, int64(limit+1)))
	if len(b) > limit || readErr != nil {
		cancel()
	}
	err = cmd.Wait()
	if len(b) > limit {
		return fail(5, "tinycap exceeded the bounded capture size")
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if readErr != nil {
		return readErr
	}
	if err != nil || audioToolFailed(diagnostic.String()) {
		return fail(5, "tinycap failed: %v: %s", err, strings.TrimSpace(diagnostic.String()))
	}
	pcm, err := capturedPCM(b, rate)
	if err != nil {
		return fail(5, "invalid tinycap capture: %v: %s", err, strings.TrimSpace(diagnostic.String()))
	}
	stats := pcmStatistics(pcm, rate)
	stats["card"], stats["device"] = v["card"], v["device"]
	stats["requested_seconds"] = seconds
	stats["elapsed_seconds"] = time.Since(started).Seconds()
	stats["note"] = "Signal statistics only; nonzero samples alone do not prove intelligible end-to-end voice"
	return a.emit(stats)
}

// The shipped tinyplay returns exit status 0 even for an ALSA EPIPE error.
// Process success alone is therefore insufficient for these firmware tools.
func audioToolFailed(output string) bool {
	lower := strings.ToLower(output)
	for _, word := range []string{"error", "unable", "cannot", "failed"} {
		if strings.Contains(lower, word) {
			return true
		}
	}
	return false
}

func wavHeader(size, rate int) []byte {
	b := make([]byte, 44)
	copy(b, "RIFF")
	binary.LittleEndian.PutUint32(b[4:], uint32(size+36))
	copy(b[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(b[16:], 16)
	binary.LittleEndian.PutUint16(b[20:], 1)
	binary.LittleEndian.PutUint16(b[22:], 1)
	binary.LittleEndian.PutUint32(b[24:], uint32(rate))
	binary.LittleEndian.PutUint32(b[28:], uint32(rate*2))
	binary.LittleEndian.PutUint16(b[32:], 2)
	binary.LittleEndian.PutUint16(b[34:], 16)
	copy(b[36:], "data")
	binary.LittleEndian.PutUint32(b[40:], uint32(size))
	return b
}

func toneWAV(rate, seconds, frequency int) []byte {
	b := append(wavHeader(rate*seconds*2, rate), make([]byte, rate*seconds*2)...)
	for i := 0; i < rate*seconds; i++ {
		// Gentle 10 ms fades, and a half-second cadence for recognition.
		x := i % rate
		gain := 0.0
		if x < rate/2 {
			gain = math.Min(1, math.Min(float64(x)/float64(rate/100), float64(rate/2-x)/float64(rate/100)))
		}
		v := int16(32767 * math.Pow(10, -24.0/20) * gain * math.Sin(2*math.Pi*float64(frequency*i)/float64(rate)))
		binary.LittleEndian.PutUint16(b[44+i*2:], uint16(v))
	}
	return b
}

func capturedPCM(b []byte, rate int) ([]byte, error) {
	if len(b) < 46 {
		return nil, fmt.Errorf("no complete PCM samples")
	}
	// On a nonseekable FD the firmware tinycap appends its final WAV header
	// after PCM. Also accept conventional header-first output from other builds.
	for _, offset := range []int{len(b) - 44, 0} {
		h := b[offset : offset+44]
		if string(h[:4]) != "RIFF" || string(h[8:16]) != "WAVEfmt " || string(h[36:40]) != "data" {
			continue
		}
		if binary.LittleEndian.Uint32(h[16:]) != 16 || binary.LittleEndian.Uint16(h[20:]) != 1 || binary.LittleEndian.Uint16(h[22:]) != 1 || binary.LittleEndian.Uint32(h[24:]) != uint32(rate) || binary.LittleEndian.Uint16(h[34:]) != 16 {
			return nil, fmt.Errorf("unexpected PCM format")
		}
		size := int(binary.LittleEndian.Uint32(h[40:]))
		if size != len(b)-44 || size == 0 || size%2 != 0 {
			return nil, fmt.Errorf("capture length mismatch")
		}
		if offset == 0 {
			return b[44:], nil
		}
		return b[:offset], nil
	}
	return nil, fmt.Errorf("missing final WAV header")
}

func pcmStatistics(b []byte, rate int) map[string]any {
	var sum, sumsq float64
	peak, nonzero, clipped := 0, 0, 0
	n := len(b) / 2
	for i := 0; i < n; i++ {
		x := int(int16(binary.LittleEndian.Uint16(b[2*i:])))
		sum += float64(x)
		sumsq += float64(x) * float64(x)
		if x < 0 {
			x = -x
		}
		if x > peak {
			peak = x
		}
		if x != 0 {
			nonzero++
		}
		if x >= 32767 {
			clipped++
		}
	}
	rms, mean := 0.0, 0.0
	if n > 0 {
		rms = math.Sqrt(sumsq / float64(n))
		mean = sum / float64(n)
	}
	acRMS := math.Sqrt(math.Max(0, rms*rms-mean*mean))
	return map[string]any{"pcm_bytes": len(b), "samples": n, "rate": rate, "duration_seconds": float64(n) / float64(rate), "peak": peak, "rms": rms, "ac_rms": acRMS, "mean": mean, "nonzero_samples": nonzero, "clipped_samples": clipped}
}
