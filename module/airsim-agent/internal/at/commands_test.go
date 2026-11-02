package at

import (
	"bufio"
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSixDigitDialWritesExactCommand(t *testing.T) {
	for _, number := range []string{"123456", "012345", "+123456"} {
		t.Run(number, func(t *testing.T) {
			a, b := net.Pipe()
			defer b.Close()
			b.SetDeadline(time.Now().Add(3 * time.Second))
			m := New(a, filepath.Join(t.TempDir(), "inflight"))
			defer m.Close()
			done := make(chan error, 1)
			go func() {
				cmd, err := bufio.NewReader(b).ReadString('\r')
				if err != nil {
					done <- err
					return
				}
				if cmd != "ATD"+number+";\r" {
					t.Error("dial command changed the number")
				}
				_, err = b.Write([]byte("\r\nOK\r\n"))
				done <- err
			}()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			if _, err := m.Command(ctx, "ATD"+number+";", ""); err != nil {
				t.Fatal(err)
			}
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestDialRejectsInvalidNumbersBeforeWriting(t *testing.T) {
	// No transport is needed: invalid commands must fail before reaching submit.
	m := &Manager{}
	for _, number := range []string{"12345", "1234567890123456", "１２３４５６", "123 456", "123456\n", "123456;\rAT+CFUN=1,1", "*123456#", "++123456"} {
		if _, err := m.Command(context.Background(), "ATD"+number+";", ""); err != ErrInvalid {
			t.Fatalf("invalid dial number accepted: %q", number)
		}
	}
}

func TestSMSDeleteOnlyBoundedIndexWithoutArguments(t *testing.T) {
	m := &Manager{}
	for _, cmd := range []string{"AT+CMGD=-1", "AT+CMGD=65536", "AT+CMGD=01", "AT+CMGD=1,0", "AT+CMGD=1;AT+CFUN=1,1"} {
		if _, err := m.Command(context.Background(), cmd, ""); err != ErrInvalid {
			t.Fatal("unbounded SMS deletion accepted")
		}
	}
	if _, err := m.Command(context.Background(), "AT+CMGD=1", "00"); err != ErrInvalid {
		t.Fatal("deletion accepted payload")
	}
}

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
