package main

import (
	"bytes"
	"encoding/binary"
	"math"
	"testing"
)

func TestCapturePipeFraming(t *testing.T) {
	pcm := []byte{0, 0, 1, 0, 255, 255, 0, 128}
	header := wavHeader(len(pcm), 8000)
	for _, input := range [][]byte{append(append([]byte{}, header...), pcm...), append(append([]byte{}, pcm...), header...)} {
		out, err := capturedPCM(input, 8000)
		if err != nil || !bytes.Equal(out, pcm) {
			t.Fatalf("valid pipe framing rejected: %v", err)
		}
		if _, err := capturedPCM(input, 16000); err == nil {
			t.Fatal("wrong sample rate accepted")
		}
		if _, err := capturedPCM(input[:len(input)-1], 8000); err == nil {
			t.Fatal("truncated capture accepted")
		}
	}
	if _, err := capturedPCM(wavHeader(0, 8000), 8000); err == nil {
		t.Fatal("empty capture accepted")
	}
	bad := append(wavHeader(len(pcm), 8000), pcm...)
	binary.LittleEndian.PutUint16(bad[22:], 2)
	if _, err := capturedPCM(bad, 8000); err == nil {
		t.Fatal("stereo capture accepted as mono")
	}
}

func TestAudioStatisticsAndTone(t *testing.T) {
	// Known signed little-endian samples, including negative full scale.
	input := []byte{0, 0, 0xff, 0x7f, 0, 0x80, 1, 0}
	s := pcmStatistics(input, 8000)
	if s["samples"] != 4 || s["peak"] != 32768 || s["nonzero_samples"] != 3 || s["clipped_samples"] != 2 || s["mean"] != 0.0 {
		t.Fatalf("incorrect signed PCM statistics: %v", s)
	}
	expectedRMS := math.Sqrt((32767.0*32767 + 32768.0*32768 + 1) / 4)
	if math.Abs(s["rms"].(float64)-expectedRMS) > 1e-8 {
		t.Fatal("incorrect RMS")
	}
	dc := pcmStatistics([]byte{100, 0, 100, 0}, 8000)
	if dc["ac_rms"] != 0.0 || dc["mean"] != 100.0 {
		t.Fatal("DC offset mistaken for AC signal")
	}
	for _, rate := range []int{8000, 16000} {
		b := toneWAV(rate, 2, 440)
		pcm, err := capturedPCM(b, rate)
		if err != nil || len(pcm) != rate*4 {
			t.Fatalf("invalid generated tone: %v", err)
		}
		stats := pcmStatistics(pcm, rate)
		if stats["peak"].(int) < 2000 || stats["peak"].(int) > 2070 || stats["clipped_samples"].(int) != 0 {
			t.Fatal("tone level outside -24 dBFS bound")
		}
		if !bytes.Equal(pcm[rate:rate*2], make([]byte, rate)) {
			t.Fatal("missing half-second silence")
		}
	}
}

func TestFirmwareAudioErrorDetection(t *testing.T) {
	for _, message := range []string{"Error playing sample.ret:-32.\nPlaying sample: 1 ch, 8000 hz, 16 bit", "Unable to open PCM device", "cannot open device", "pcm read failed"} {
		if !audioToolFailed(message) {
			t.Fatalf("firmware failure accepted: %s", message)
		}
	}
	if audioToolFailed("Playing sample: 1 ch, 8000 hz, 16 bit\n") {
		t.Fatal("normal playback output rejected")
	}
}
