package media

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

func listen(path string) (*net.UnixListener, func(), error) {
	dir, e := os.Lstat(filepath.Dir(path))
	if e != nil || !dir.IsDir() || dir.Mode().Perm() != 0700 {
		return nil, nil, errors.New("media_directory")
	}
	if info, e := os.Lstat(path); e == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, nil, errors.New("media_socket_conflict")
		}
		c, e := net.DialTimeout("unix", path, 200*time.Millisecond)
		if e == nil {
			c.Close()
			return nil, nil, errors.New("media_socket_conflict")
		}
		if !errors.Is(e, syscall.ECONNREFUSED) {
			return nil, nil, errors.New("media_socket_conflict")
		}
		current, e := os.Lstat(path)
		if e != nil || !os.SameFile(info, current) {
			return nil, nil, errors.New("media_socket_conflict")
		}
		if e = os.Remove(path); e != nil {
			return nil, nil, e
		}
	} else if !os.IsNotExist(e) {
		return nil, nil, e
	}
	l, e := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if e != nil {
		return nil, nil, e
	}
	l.SetUnlinkOnClose(false)
	owned, e := os.Lstat(path)
	if e != nil {
		l.Close()
		return nil, nil, e
	}
	cleanup := func() {
		l.Close()
		current, e := os.Lstat(path)
		if e == nil && os.SameFile(owned, current) {
			os.Remove(path)
		}
	}
	if e = os.Chmod(path, 0600); e != nil {
		cleanup()
		return nil, nil, e
	}
	return l, cleanup, nil
}
func (m *Manager) Serve(ctx context.Context) {
	defer close(m.done)
	stop := context.AfterFunc(ctx, m.cancel)
	defer stop()
	l, cleanup, e := listen(m.socket)
	if e != nil {
		m.mu.Lock()
		m.err = "media_socket_unavailable"
		m.mu.Unlock()
		m.cancel()
		return
	}
	defer cleanup()
	m.mu.Lock()
	m.listening = true
	m.mu.Unlock()
	stopListener := context.AfterFunc(m.ctx, func() { l.Close() })
	defer stopListener()
	watchDone := make(chan struct{})
	go func() { defer close(watchDone); m.watch() }()
	slots := make(chan struct{}, 4)
	for {
		conn, e := l.AcceptUnix()
		if e != nil {
			break
		}
		select {
		case slots <- struct{}{}:
			m.wg.Add(1)
			go func() {
				defer m.wg.Done()
				defer func() { <-slots }()
				stop := context.AfterFunc(m.ctx, func() { conn.Close() })
				defer stop()
				m.authenticate(conn)
			}()
		default:
			conn.Close()
		}
	}
	m.mu.Lock()
	m.listening = false
	m.cancel()
	if m.active != nil {
		m.stopLocked(m.active, "agent_stopping")
	}
	m.mu.Unlock()
	<-watchDone
	m.wg.Wait()
}
