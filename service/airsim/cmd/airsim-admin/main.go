package main

import (
	"airsim.local/server/internal/admin"
	rt "airsim.local/server/internal/runtime"
	"airsim.local/server/internal/store"
	"context"
	"errors"
	"flag"
	"time"
)

func main() {
	op := flag.String("operation", "", "init, issue-client, revoke-client, issue-module")
	dir := flag.String("secrets-dir", "", "protected directory")
	out := flag.String("output", "", "explicit 0600 output")
	req := flag.String("request", "", "prepare request")
	res := flag.String("response", "", "prepare response")
	id := flag.String("client-id", "", "client to revoke")
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, e := store.Open(ctx)
	rt.Exit(e)
	defer db.Close()
	switch *op {
	case "init":
		e = admin.Init(ctx, db, *dir)
	case "issue-client":
		e = admin.Client(ctx, db, *out)
	case "issue-module":
		e = admin.Issue(ctx, db, *dir, *req, *res, *out)
	case "revoke-client":
		_, e = db.Exec(ctx, "UPDATE clients SET revoked=true WHERE id=$1", *id)
	default:
		e = errors.New("invalid_operation")
	}
	rt.Exit(e)
}
