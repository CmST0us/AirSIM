package at

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestKilledInflightProcess(t *testing.T) {
	if path := os.Getenv("AIRSIM_TEST_FENCE"); path != "" {
		a, b := net.Pipe()
		m := New(a, path)
		go func() { buf := make([]byte, 100); b.Read(buf); fmt.Println("inflight") }()
		m.Query(context.Background(), "AT+CSQ")
		os.Exit(2)
	}
	path := filepath.Join(t.TempDir(), "fence")
	binary, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	cmd := exec.Command(binary, "-test.run=^TestKilledInflightProcess$")
	cmd.Env = append(os.Environ(), "AIRSIM_TEST_FENCE="+path)
	out, e := cmd.StdoutPipe()
	if e != nil {
		t.Fatal(e)
	}
	if e = cmd.Start(); e != nil {
		t.Fatal(e)
	}
	defer cmd.Process.Kill()
	ready := make(chan bool)
	go func() { scanner := bufio.NewScanner(out); ready <- scanner.Scan() && scanner.Text() == "inflight" }()
	select {
	case ok := <-ready:
		if !ok {
			t.Fatal("not inflight")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timeout")
	}
	if e = cmd.Process.Kill(); e != nil {
		t.Fatal(e)
	}
	cmd.Wait()
	if !FencePresent(path) {
		t.Fatal("kill removed fence")
	}
	if !FencePresent(path) {
		t.Fatal("restart would open device")
	}
}
