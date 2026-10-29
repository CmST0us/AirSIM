package at

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var ErrDesynchronized = errors.New("at_desynchronized")
var ErrQuery = errors.New("query_failed")
var ErrInvalid = errors.New("invalid_response")
var allowed = map[string]string{"ATI": "", "AT+CGMR": "", "AT+CPIN?": "+CPIN:", "AT+CSQ": "+CSQ:", "AT+CREG?": "+CREG:", "AT+CGREG?": "+CGREG:", "AT+CEREG?": "+CEREG:", "AT+CIREG?": "+CIREG:", "AT+COPS?": "+COPS:", "AT+CLCC": "+CLCC:"}

type result struct {
	lines []string
	err   error
}
type request struct {
	ctx                    context.Context
	command                string
	reply                  chan result
	label, prefix, payload string
	timeout                time.Duration
	pduLines               bool
}
type Manager struct {
	port            io.ReadWriteCloser
	marker          string
	queue           chan request
	lines           chan string
	fault           chan struct{}
	done            chan struct{}
	readerDone      chan struct{}
	stop            chan struct{}
	once            sync.Once
	events          chan struct{}
	overflow        chan struct{}
	activity        chan struct{}
	quiesce         chan struct{}
	quiesceOnce     sync.Once
	diagnosticCount atomic.Uint32
}

func New(port io.ReadWriteCloser, marker string) *Manager {
	m := &Manager{port: port, marker: marker, queue: make(chan request, 16), lines: make(chan string, 64), fault: make(chan struct{}, 1), done: make(chan struct{}), readerDone: make(chan struct{}), stop: make(chan struct{}), events: make(chan struct{}, 64), overflow: make(chan struct{}, 1), activity: make(chan struct{}, 1), quiesce: make(chan struct{})}
	go m.read()
	go m.run()
	return m
}
func (m *Manager) fail() {
	select {
	case m.fault <- struct{}{}:
	default:
	}
}
func (m *Manager) read() {
	defer close(m.readerDone)
	b := make([]byte, 1024)
	pending := ""
	for {
		n, e := m.port.Read(b)
		if n > 0 {
			select {
			case m.activity <- struct{}{}:
			default:
			}
			pending += string(b[:n])
			for {
				if strings.HasPrefix(pending, ">") {
					select {
					case m.lines <- ">":
					case <-m.stop:
						return
					case <-m.done:
						return
					}
					pending = strings.TrimPrefix(pending[1:], " ")
				}
				i := strings.IndexAny(pending, "\r\n")
				if i < 0 {
					if len(pending) > 4096 {
						m.fail()
						return
					}
					break
				}
				if i > 4096 {
					m.fail()
					return
				}
				line := strings.TrimSpace(pending[:i])
				pending = pending[i+1:]
				if line != "" {
					select {
					case m.lines <- line:
					case <-m.stop:
						return
					case <-m.done:
						return
					}
				}
			}
		}
		if e != nil {
			m.diagnostic("AT reader stopped: %v", e)
			m.fail()
			return
		}
		select {
		case <-m.stop:
			return
		default:
		}
	}
}
func (m *Manager) Query(ctx context.Context, cmd string) ([]string, error) {
	if _, ok := allowed[cmd]; !ok {
		return nil, ErrInvalid
	}
	return m.submit(request{ctx: ctx, command: cmd, label: cmd, prefix: allowed[cmd], timeout: 5 * time.Second})
}
func (m *Manager) submit(r request) ([]string, error) {
	ctx := r.ctx
	r.reply = make(chan result, 1)
	select {
	case <-m.quiesce:
		return nil, ErrQuery
	case <-m.done:
		return nil, ErrDesynchronized
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}
	select {
	case m.queue <- r:
	case <-m.done:
		return nil, ErrDesynchronized
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
		return nil, ErrQuery
	}
	select {
	case x := <-r.reply:
		return x.lines, x.err
	case <-m.done:
		select {
		case x := <-r.reply:
			return x.lines, x.err
		default:
			return nil, ErrDesynchronized
		}
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
func (m *Manager) Close() {
	m.once.Do(func() { close(m.stop); m.port.Close() })
	<-m.done
	<-m.readerDone
}
func (m *Manager) Done() <-chan struct{} { return m.done }
func (m *Manager) drain() bool {
	quiet := time.NewTimer(500 * time.Millisecond)
	defer quiet.Stop()
	limit := time.NewTimer(5 * time.Second)
	defer limit.Stop()
	for {
		select {
		case <-quiet.C:
			return true
		case <-limit.C:
			return false
		case <-m.stop:
			return false
		case <-m.fault:
			return false
		case <-m.activity:
			if !quiet.Stop() {
				select {
				case <-quiet.C:
				default:
				}
			}
			quiet.Reset(500 * time.Millisecond)
		case <-m.lines:
			if !quiet.Stop() {
				select {
				case <-quiet.C:
				default:
				}
			}
			quiet.Reset(500 * time.Millisecond)
		}
	}
}
func (m *Manager) run() {
	defer close(m.done)
	defer m.port.Close()
	if !m.drain() {
		m.diagnostic("AT startup drain unavailable")
		return
	}
	for {
		select {
		case <-m.stop:
			return
		case <-m.quiesce:
			return
		case <-m.fault:
			return
		case line := <-m.lines:
			if !urc(line) {
				kind := "unclassified"
				for _, prefix := range []string{"+CME ERROR:", "+CMS ERROR:", "+CGEV:", "+QIND:", "+CPIN:", "+CFUN:", "+COPS:", "+CLCC:", "+CSQ:", "+CIEV:", "+CTZV:", "+CTZE:", "+CCLK:", "^", "+"} {
					if strings.HasPrefix(line, prefix) {
						kind = "prefix_" + prefix
						break
					}
				}
				switch line {
				case "OK", "ERROR", "ATI", "AT+CGMR", "Quectel", "RM500U-CN", "Revision: RM500UCNAAR01A18M2G":
					kind = line
				}
				m.diagnostic("AT unexpected idle response; class=%s bytes=%d nul=%t; session stopped", kind, len(line), strings.ContainsRune(line, 0))
				return
			}
			m.event()
		case r := <-m.queue:
			select {
			case <-m.quiesce:
				r.reply <- result{err: ErrQuery}
				return
			default:
			}
			if r.ctx.Err() != nil {
				r.reply <- result{err: r.ctx.Err()}
				continue
			}
			x, broken := m.execute(r)
			r.reply <- x
			if broken {
				return
			}
		}
	}
}
func urc(s string) bool {
	return s == "RING" || s == "NO CARRIER" || strings.HasPrefix(s, "+CMTI:") || strings.HasPrefix(s, "+CLIP:") || strings.HasPrefix(s, "+QIND:") || strings.HasPrefix(s, "+CGEV:") || strings.HasPrefix(s, "+CREG:") || strings.HasPrefix(s, "+CGREG:") || strings.HasPrefix(s, "+CEREG:") || strings.HasPrefix(s, "+CIREG:")
}
func (m *Manager) execute(r request) (result, bool) {
	// This tmpfs fence intentionally survives a failed transaction or process death.
	f, e := os.OpenFile(m.marker, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return result{err: ErrDesynchronized}, true
	}
	_, e = f.WriteString("{\"command\":\"" + r.label + "\"}\n")
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e != nil || ce != nil {
		return result{err: ErrDesynchronized}, true
	}
	timer := time.NewTimer(r.timeout)
	defer timer.Stop()
	write := func(payload []byte) bool {
		written := make(chan bool, 1)
		go func() {
			n, e := m.port.Write(payload)
			written <- e == nil && n == len(payload)
		}()
		select {
		case ok := <-written:
			return ok
		case <-timer.C:
		case <-r.ctx.Done():
		case <-m.stop:
		}
		m.port.Close()
		<-written
		return false
	}
	if !write([]byte(r.command + "\r")) {
		return result{err: ErrDesynchronized}, true
	}
	prompted := false

	lines := []string{}
	size := 0
	for {
		select {
		case <-m.stop:
			return result{err: ErrDesynchronized}, true
		case <-m.fault:
			return result{err: ErrDesynchronized}, true
		case <-timer.C:
			return result{err: ErrDesynchronized}, true
		case <-r.ctx.Done():
			return result{err: ErrDesynchronized}, true
		case line := <-m.lines:
			size += len(line)
			if size > 16384 {
				return result{err: ErrDesynchronized}, true
			}
			if line == ">" && r.payload != "" && !prompted {
				prompted = true
				if !write([]byte(r.payload + "\x1a")) {
					return result{err: ErrDesynchronized}, true
				}
				continue
			}
			if line == r.command || (r.payload != "" && line == r.payload) {
				continue
			}
			dialFailed := strings.HasPrefix(r.command, "ATD") && (line == "NO CARRIER" || line == "NO ANSWER" || line == "BUSY" || line == "NO DIALTONE")
			if dialFailed || line == "OK" || line == "ERROR" || strings.HasPrefix(line, "+CME ERROR:") || strings.HasPrefix(line, "+CMS ERROR:") {
				if e := os.Remove(m.marker); e != nil {
					return result{err: ErrDesynchronized}, true
				}
				if line != "OK" {
					code := -1
					kind := "error"
					for _, prefix := range []string{"+CME ERROR:", "+CMS ERROR:"} {
						if strings.HasPrefix(line, prefix) {
							if n, e := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, prefix))); e == nil {
								code = n
							}
							if prefix == "+CME ERROR:" {
								kind = "cme"
							} else {
								kind = "cms"
							}
						}
					}
					m.diagnostic("AT transaction query_failed: command=%s terminal=%s code=%d", r.label, kind, code)
					return result{err: ErrQuery}, false
				}
				return result{lines: lines}, false
			}
			prefix := r.prefix
			if prefix != "" && strings.HasPrefix(line, prefix) {
				// Registration query responses include reporting mode and registration; URCs don't.
				if (strings.Contains(r.command, "REG?")) && !strings.Contains(line, ",") {
					m.event()
					continue
				}
				lines = append(lines, line)
				continue
			}
			if urc(line) {
				m.event()
				continue
			}
			if r.command == "ATI" || r.command == "AT+CGMR" || (r.pduLines && hexPDU.MatchString(line)) {
				lines = append(lines, line)
				continue
			}
			return result{err: ErrInvalid}, true
		}
	}
}

func (m *Manager) Events() <-chan struct{}   { return m.events }
func (m *Manager) Overflow() <-chan struct{} { return m.overflow }
func (m *Manager) event() {
	select {
	case m.events <- struct{}{}:
	default:
		select {
		case m.overflow <- struct{}{}:
		default:
		}
	}
}

func (m *Manager) Quiesce()       { m.quiesceOnce.Do(func() { close(m.quiesce) }) }
func (m *Manager) GracefulClose() { m.Quiesce(); <-m.done; m.Close() }

func (m *Manager) diagnostic(format string, args ...any) {
	if m.diagnosticCount.Add(1) <= 32 {
		log.Printf(format, args...)
	}
}
