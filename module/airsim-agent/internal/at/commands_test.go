package at

import (
	"bufio"
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSMSPromptAndPrivateFence(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	m := New(a, filepath.Join(t.TempDir(), "inflight"))
	defer m.Close()
	done := make(chan error, 1)
	go func() {
		r := bufio.NewReader(b)
		cmd, err := r.ReadString('\r')
		if err != nil {
			done <- err
			return
		}
		if cmd != "AT+CMGS=2\r" {
			t.Error("wrong SMS command")
		}
		f, err := os.ReadFile(m.marker)
		if err != nil {
			done <- err
			return
		}
		if strings.Contains(string(f), "CMGS") || !strings.Contains(string(f), "sms.send") {
			t.Error("fence contains arguments")
		}
		b.Write([]byte("\r\n>"))
		b.Write([]byte(" "))
		payload, err := r.ReadString(26)
		if err != nil {
			done <- err
			return
		}
		if payload != "000102\x1a" {
			t.Error("wrong PDU payload")
		}
		_, err = b.Write([]byte("\r\n+CMTI: \"ME\",5\r\n+CMGS: 9\r\nOK\r\n"))
		done <- err
	}()
	lines, err := m.Command(context.Background(), "AT+CMGS=2", "000102")
	if err != nil || len(lines) != 1 || lines[0] != "+CMGS: 9" {
		t.Fatalf("SMS transaction failed: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if _, err = m.Query(context.Background(), "ATA"); err != ErrInvalid {
		t.Fatal("read-only query accepted a write")
	}
	if _, err = m.Command(context.Background(), "ATD1234567;\rAT+CFUN=1,1", ""); err != ErrInvalid {
		t.Fatal("accepted injected command")
	}
}
