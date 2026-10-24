package main

import (
	"airsim.local/server/internal/control"
	"airsim.local/server/internal/media"
	rt "airsim.local/server/internal/runtime"
	"os"
)

func main() {
	rt.Health()
	ctx, cancel := rt.Context()
	defer cancel()
	token, e := control.Secret(os.Getenv("MEDIA_TOKEN_FILE"))
	rt.Exit(e)
	s := media.New(token)
	go s.Run(ctx)
	rt.Exit(rt.Serve(ctx, s.Handler()))
}
