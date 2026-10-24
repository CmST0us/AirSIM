package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testApp() (*app, *bytes.Buffer, *bytes.Buffer) {
	out, err := &bytes.Buffer{}, &bytes.Buffer{}
	return &app{in: strings.NewReader(""), out: out, err: err, opts: options{JSON: true, Baud: 115200, Timeout: time.Second}}, out, err
}
func TestCatalogDiscoveryAndValidation(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range catalog() {
		if seen[c.Name] {
			t.Fatalf("duplicate %s", c.Name)
		}
		seen[c.Name] = true
		a, out, _ := testApp()
		if err := a.run(context.Background(), append(strings.Fields(c.Name), "--help")); err != nil {
			t.Fatal(err)
		}
		if !json.Valid(out.Bytes()) {
			t.Fatal(c.Name)
		}
		if _, err := validateFlags(c, map[string]string{"does-not-exist": "x"}); err == nil {
			t.Fatal("unknown flag accepted")
		}
	}
	a, out, _ := testApp()
	if err := a.run(context.Background(), []string{"schema"}); err != nil || !json.Valid(out.Bytes()) {
		t.Fatal(err)
	}
}
func TestInputAndInjection(t *testing.T) {
	cases := [][]string{
		{"calls", "dial", "--number", "12;AT+CFUN=1,1"},
		{"data", "set-apn", "--cid", "1", "--type", "IP", "--apn", "x\";ATZ"},
		{"at", "exec", "--command", "AT\rATZ"},
		{"network", "link-set", "--interface", "../../etc", "--state", "up"},
		{"network", "ping", "--host", "-f"},
		{"calls", "dial"}, {"calls", "dial", "--number", "1", "--number", "2"},
		{"device", "info", "--timeout", "0s"}, {"device", "info", "--unknown", "x"},
	}
	for _, args := range cases {
		a, _, _ := testApp()
		args = append(args, "--dry-run")
		if err := a.run(context.Background(), args); err == nil {
			t.Fatalf("accepted %q", args)
		}
	}
	a, out, _ := testApp()
	if err := a.run(context.Background(), []string{"sms", "send", "--number", "+12345", "--text", "hello", "--dry-run"}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "12345") || strings.Contains(out.String(), "hello") {
		t.Fatal("dry run exposed payload")
	}
}
func TestShellQuoting(t *testing.T) {
	words, e := splitLine(`sms send --number '+123' --text "a b 'c'"`)
	if e != nil || len(words) != 6 || words[5] != "a b 'c'" {
		t.Fatalf("%v %v", words, e)
	}
	if _, e = splitLine(`at exec --command "AT`); e == nil {
		t.Fatal("unclosed quote accepted")
	}
}

type scriptPort struct {
	replies [][]byte
	writes  bytes.Buffer
}

func (s *scriptPort) Read(b []byte) (int, error) {
	if len(s.replies) == 0 {
		return 0, nil
	}
	n := copy(b, s.replies[0])
	s.replies[0] = s.replies[0][n:]
	if len(s.replies[0]) == 0 {
		s.replies = s.replies[1:]
	}
	return n, nil
}
func (s *scriptPort) Write(b []byte) (int, error) { return s.writes.Write(b) }
func (s *scriptPort) Close() error                { return nil }
func TestATFragmentedTerminalAndError(t *testing.T) {
	p := &scriptPort{replies: [][]byte{[]byte("AT+CSQ\r\n+CSQ: 20,99\r\nO"), []byte("K\r"), []byte("\n")}}
	s := &atSession{port: p}
	r, e := s.command(context.Background(), "AT+CSQ")
	if e != nil || r.Fields["+CSQ"][0] != "20,99" || p.writes.String() != "AT+CSQ\r" {
		t.Fatalf("%v %v", r, e)
	}
	for _, line := range []string{"ERROR", "+CME ERROR: 10", "+CMS ERROR: 500", "NO CARRIER", "BUSY", "CONNECT"} {
		p = &scriptPort{replies: [][]byte{[]byte("\r\n" + line + "\r\n")}}
		s = &atSession{port: p}
		if _, e = s.command(context.Background(), "AT"); e == nil {
			t.Fatal("false success", line)
		}
	}
}
func TestATTimeoutAndPrompt(t *testing.T) {
	s := &atSession{port: &scriptPort{}}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, e := s.command(ctx, "AT"); e != context.DeadlineExceeded {
		t.Fatal(e)
	}
	s = &atSession{port: &scriptPort{replies: [][]byte{[]byte("\r\n> ")}}}
	if _, e := s.read(context.Background(), true); e != nil {
		t.Fatal(e)
	}
}
func TestSMSPDU(t *testing.T) {
	pdu, e := makeSMSPDU("+12345", "你好")
	if e != nil {
		t.Fatal(e)
	}
	if pdu != "00010005912143F50008044F60597D" {
		t.Fatal(pdu)
	}
	b, _ := hex.DecodeString(pdu)
	if len(b)-1 != 14 {
		t.Fatal("CMGS length")
	}
	for _, s := range []string{"", strings.Repeat("x", 71), strings.Repeat("😀", 36)} {
		if _, e = makeSMSPDU("+12345", s); e == nil {
			t.Fatal("invalid length accepted")
		}
	}
}
func TestSMSPromptExchange(t *testing.T) {
	// One read fragment per transaction avoids pretending synchronous replies
	// arrive before commands; a real PTY/device smoke test is separate.
	p := &scriptPort{replies: [][]byte{[]byte("+CMGF: 0\r\nOK\r\n"), []byte("> "), []byte("+CMGS: 7\r\nOK\r\n")}}
	a, out, _ := testApp()
	if e := a.sms(context.Background(), &atSession{port: p}, "sms send", map[string]string{"number": "+12345", "text": "你好"}); e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(p.writes.String(), "AT+CMGS=14\r00010005912143F50008044F60597D\x1a") || !json.Valid(out.Bytes()) {
		t.Fatal(p.writes.String())
	}
}

func TestSMSRestoreFailureDoesNotEmitSuccess(t *testing.T) {
	p := &scriptPort{replies: [][]byte{
		[]byte("+CMGF: 1\r\nOK\r\n"), []byte("OK\r\n"),
		[]byte("OK\r\n"), []byte("ERROR\r\n"),
	}}
	a, out, _ := testApp()
	if e := a.sms(context.Background(), &atSession{port: p}, "sms list", nil); e == nil {
		t.Fatal("restore error swallowed")
	}
	if out.Len() != 0 {
		t.Fatal("emitted success before restore")
	}
}
func TestAgentHTTP(t *testing.T) {
	var got bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = true
		if r.Method != "POST" || r.URL.Path != "/api/calls/dial" || r.Header.Get("Authorization") != "Bearer token" {
			t.Error("wrong request")
		}
		var v map[string]string
		if e := json.NewDecoder(r.Body).Decode(&v); e != nil || v["number"] != "12345" {
			t.Error("wrong payload")
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"dialing":true}`)
	}))
	defer srv.Close()
	token := filepath.Join(t.TempDir(), "token")
	os.WriteFile(token, []byte("token\n"), 0600)
	a, out, _ := testApp()
	a.opts.Endpoint = srv.URL
	a.opts.TokenFile = token
	if e := a.run(context.Background(), []string{"agent", "request", "--method", "POST", "--path", "/api/calls/dial", "--data", `{"number":"12345"}`}); e != nil || !got || !json.Valid(out.Bytes()) {
		t.Fatal(e)
	}
}
func TestAgentRejectRedirectAndEscapes(t *testing.T) {
	hit := false
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hit = true }))
	defer destination.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, destination.URL, 307) }))
	defer redirect.Close()
	for _, path := range []string{"/api/health", "//example.com/api/health", "https://example.com/api/health", "/api/../health"} {
		a, _, _ := testApp()
		a.opts.Endpoint = redirect.URL
		if e := a.run(context.Background(), []string{"agent", "request", "--method", "GET", "--path", path}); e == nil {
			t.Fatal("accepted", path)
		}
	}
	if hit {
		t.Fatal("followed redirect")
	}
}
func TestTCPAndPCMStreams(t *testing.T) {
	for _, pcm := range []bool{false, true} {
		t.Run(map[bool]string{false: "tcp", true: "pcm"}[pcm], func(t *testing.T) {
			listener, e := net.Listen("tcp", "127.0.0.1:0")
			if e != nil {
				t.Fatal(e)
			}
			defer listener.Close()
			done := make(chan error, 1)
			go func() {
				c, e := listener.Accept()
				if e != nil {
					done <- e
					return
				}
				defer c.Close()
				c.SetDeadline(time.Now().Add(time.Second))
				if pcm {
					b := make([]byte, 11)
					_, e = io.ReadFull(c, b)
					if e != nil || string(b) != "AIRSIMPCM1\n" {
						done <- fail(1, "bad handshake")
						return
					}
					io.WriteString(c, "AIRSIMREADY")
				}
				b, e := io.ReadAll(c)
				if e == nil {
					_, e = c.Write(b)
				}
				done <- e
			}()
			a, out, _ := testApp()
			a.opts.JSON = false
			a.in = bytes.NewReader([]byte{0, 1, 0xff, 0x80})
			name := "stream tcp"
			if pcm {
				name = "stream pcm"
			}
			if e = a.runStream(context.Background(), command{Name: name}, map[string]string{"address": listener.Addr().String()}); e != nil {
				t.Fatal(e)
			}
			if e = <-done; e != nil {
				t.Fatal(e)
			}
			if !bytes.Equal(out.Bytes(), []byte{0, 1, 0xff, 0x80}) {
				t.Fatal("stream corrupted")
			}
		})
	}
}
func TestInstalledBinary(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "rm500")
	build := exec.Command("go", "build", "-o", bin, ".")
	if out, e := build.CombinedOutput(); e != nil {
		t.Fatalf("build: %s %v", out, e)
	}
	for _, args := range [][]string{{"version", "--json"}, {"schema", "--json"}, {"calls", "dial", "--number", "12345", "--dry-run", "--json"}} {
		cmd := exec.Command(bin, args...)
		cmd.Dir = t.TempDir()
		out, e := cmd.Output()
		if e != nil || !json.Valid(out) {
			t.Fatalf("%v: %s %v", args, out, e)
		}
	}
	cmd := exec.Command(bin, "calls", "dial", "--json")
	out, e := cmd.CombinedOutput()
	if e == nil || !json.Valid(out) {
		t.Fatalf("expected structured failure: %s %v", out, e)
	}
}
