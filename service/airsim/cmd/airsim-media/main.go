package main

import (
	"airsim.local/server/internal/control"
	"airsim.local/server/internal/ice"
	"airsim.local/server/internal/media"
	rt "airsim.local/server/internal/runtime"
	"errors"
	"fmt"
	"net"
	"os"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "healthcheck" {
		if media.Healthy(fmt.Sprintf("127.0.0.1:%d", ice.Port)) {
			os.Exit(0)
		}
		os.Exit(1)
	}
	ctx, cancel := rt.Context()
	defer cancel()
	secret, e := control.Secret(os.Getenv("TURN_SECRET_FILE"))
	rt.Exit(e)
	ip := net.ParseIP(os.Getenv("AIRSIM_TURN_IP"))
	if ip.To4() == nil || !media.PeerAllowed(ip) {
		rt.Exit(errors.New("turn_ip_invalid"))
	}
	rt.Exit(media.Serve(ctx, media.Config{Secret: secret, PublicIP: ip, Listen: rt.Env("TURN_LISTEN_ADDR", "0.0.0.0")}))
}
