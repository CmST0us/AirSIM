package main

import (
	"airsim.local/server/internal/control"
	"airsim.local/server/internal/push"
	rt "airsim.local/server/internal/runtime"
	"airsim.local/server/internal/store"
	"crypto/x509"
	"errors"
	"net/url"
	"os"
)

func main() {
	rt.Health()
	ctx, cancel := rt.Context()
	defer cancel()
	db, e := store.Open(ctx)
	rt.Exit(e)
	defer db.Close()
	rt.Exit(db.Ready(ctx))
	cfg := control.Config{API: os.Getenv("AIRSIM_API_ORIGIN"), Device: os.Getenv("AIRSIM_DEVICE_ORIGIN"), Media: os.Getenv("AIRSIM_MEDIA_ORIGIN"), MediaInternal: rt.Env("MEDIA_INTERNAL_ORIGIN", "http://media:8080")}
	for _, origin := range []string{cfg.API, cfg.Device, cfg.Media} {
		u, e := url.Parse(origin)
		if e != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
			rt.Exit(errors.New("origin_invalid"))
		}
	}
	rt.Exit(db.QueryRow(ctx, "SELECT server_id FROM identity").Scan(&cfg.Server))
	cfg.EdgeToken, e = control.Secret(os.Getenv("EDGE_TOKEN_FILE"))
	rt.Exit(e)
	cfg.MediaToken, e = control.Secret(os.Getenv("MEDIA_TOKEN_FILE"))
	rt.Exit(e)
	cfg.HMAC, e = control.Secret(os.Getenv("COMMAND_HMAC_FILE"))
	rt.Exit(e)
	b, e := os.ReadFile(os.Getenv("DEVICE_CA_FILE"))
	rt.Exit(e)
	cfg.Roots = x509.NewCertPool()
	if !cfg.Roots.AppendCertsFromPEM(b) {
		rt.Exit(errors.New("ca_invalid"))
	}
	_, e = db.Exec(ctx, "UPDATE commands SET state='outcome_unknown' WHERE state IN ('pending','dispatched')")
	rt.Exit(e)
	provider, e := push.LoadConfig(push.Config{
		TeamID: os.Getenv("APNS_TEAM_ID"), BundleID: os.Getenv("APNS_BUNDLE_ID"),
		KeyID: os.Getenv("APNS_KEY_ID"), KeyFile: os.Getenv("APNS_KEY_FILE"),
		SandboxKeyID: os.Getenv("APNS_SANDBOX_KEY_ID"), SandboxKeyFile: os.Getenv("APNS_SANDBOX_KEY_FILE"),
		ProductionKeyID: os.Getenv("APNS_PRODUCTION_KEY_ID"), ProductionKeyFile: os.Getenv("APNS_PRODUCTION_KEY_FILE"),
	})
	rt.Exit(e)
	if provider != nil {
		cfg.Push = provider
		cfg.PushBundle = os.Getenv("APNS_BUNDLE_ID")
	}
	s := control.New(db, cfg)
	go s.RunUSBRevocations(ctx)
	go s.RunPush(ctx)
	go s.Run(ctx)
	rt.Exit(rt.Serve(ctx, s.Handler()))
}
