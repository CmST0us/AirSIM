// Copied to a temporary module subdirectory by verify_ios_audio.py, so the
// production internal RTC package is exercised without a production endpoint.
package main

import (
	"airsim.local/airsim-agent/internal/rtc"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync/atomic"
	"time"
)

func main() {
	ln, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		panic("listen")
	}
	fmt.Println(ln.Addr().String())
	var primary, redundant, depthTwo, invalid atomic.Uint64
	mux := http.NewServeMux()
	mux.HandleFunc("/offer", func(w http.ResponseWriter, r *http.Request) {
		b, e := io.ReadAll(io.LimitReader(r.Body, 32769))
		if e != nil || len(b) > 32768 {
			http.Error(w, "offer", 400)
			return
		}
		p, answer, e := rtc.Answer(r.Context(), rtc.Config{LocalIP: net.IPv4(127, 0, 0, 1), GatherTimeout: 2 * time.Second}, string(b))
		if e != nil {
			http.Error(w, "answer", 400)
			return
		}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			defer p.Close()
			select {
			case <-p.Connected():
			case <-ctx.Done():
				return
			}
			go func() {
				ticker := time.NewTicker(20 * time.Millisecond)
				defer ticker.Stop()
				for {
					select {
					case <-ctx.Done():
						return
					case <-ticker.C:
						_ = p.WriteOpus([]byte{0xf8, 0xff, 0xfe}, 0)
					}
				}
			}()
			track, e := p.Track(ctx)
			if e != nil {
				return
			}
			buf := make([]byte, 1500)
			for {
				packets, e := track.ReadPacket(buf, time.Now().Add(3*time.Second))
				if e != nil {
					invalid.Add(1)
					return
				}
				n := 0
				for _, f := range packets {
					if f.Redundant {
						redundant.Add(1)
						n++
					} else {
						primary.Add(1)
					}
				}
				if n >= 2 {
					depthTwo.Add(1)
				}
			}
		}()
		w.Header().Set("Content-Type", "text/plain")
		io.WriteString(w, answer)
	})
	mux.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]uint64{"primary": primary.Load(), "redundant": redundant.Load(), "depth_two": depthTwo.Load(), "invalid": invalid.Load()})
	})
	http.Serve(ln, mux)
}
