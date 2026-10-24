package main

import (
	rt "airsim.local/server/internal/runtime"
	"airsim.local/server/internal/store"
	"context"
	"time"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, e := store.Open(ctx)
	rt.Exit(e)
	defer db.Close()
	rt.Exit(db.Migrate(ctx))
}
