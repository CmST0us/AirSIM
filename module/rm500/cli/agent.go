package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

func agentCommands() []command {
	out := []command{{Name: "agent request", Backend: "agent", Description: "Optional existing module-agent API; explicit URL required", Mutates: true, Params: []param{p("method", "enum:GET,POST,PUT,PATCH,DELETE"), p("path", "text"), optional("data", "text")}}}
	return out
}
func (a *app) runAgent(ctx context.Context, c command, v map[string]string) error {
	base, e := url.Parse(a.opts.Endpoint)
	if e != nil || base == nil || base.Host == "" || (base.Scheme != "http" && base.Scheme != "https") || base.User != nil || base.RawQuery != "" || base.Fragment != "" {
		return fail(2, "set --endpoint to an http(s) origin without credentials/query")
	}
	ref, e := url.Parse(v["path"])
	if e != nil || ref.IsAbs() || ref.Host != "" || ref.Fragment != "" || !strings.HasPrefix(ref.Path, "/api/") || strings.Contains(ref.Path, "..") {
		return fail(2, "path must remain under /api/")
	}
	data := []byte(v["data"])
	if strings.HasPrefix(v["data"], "@") {
		path := strings.TrimPrefix(v["data"], "@")
		if path == "-" {
			data, e = io.ReadAll(io.LimitReader(a.in, (1<<20)+1))
		} else {
			data, e = os.ReadFile(path)
		}
		if e != nil {
			return e
		}
	}
	if len(data) > 1<<20 {
		return fail(2, "request body exceeds 1 MiB")
	}
	if len(data) > 0 && !json.Valid(data) {
		return fail(2, "data must be valid JSON or @file/@-")
	}
	if v["method"] == "GET" && len(data) > 0 {
		return fail(2, "GET does not accept data")
	}
	ctx, cancel := context.WithTimeout(ctx, a.opts.Timeout)
	defer cancel()
	req, e := http.NewRequestWithContext(ctx, v["method"], base.ResolveReference(ref).String(), bytes.NewReader(data))
	if e != nil {
		return e
	}
	req.Header.Set("Accept", "application/json")
	if len(data) > 0 {
		req.Header.Set("Content-Type", "application/json")
	}
	if a.opts.TokenFile != "" {
		b, e := os.ReadFile(a.opts.TokenFile)
		if e != nil {
			return fail(2, "cannot read token file")
		}
		token := strings.TrimSpace(string(b))
		if token == "" || strings.ContainsAny(token, "\r\n") {
			return fail(2, "invalid token file")
		}
		req.Header.Set("Authorization", "Bearer "+token)
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	defer transport.CloseIdleConnections()
	client := http.Client{Transport: transport, Timeout: a.opts.Timeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, e := client.Do(req)
	if e != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fail(3, "agent connection failed")
	}
	defer resp.Body.Close()
	b, e := io.ReadAll(io.LimitReader(resp.Body, (4<<20)+1))
	if e != nil {
		return e
	}
	if len(b) > 4<<20 {
		return fail(3, "agent response exceeds 4 MiB")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if resp.StatusCode == 410 || resp.StatusCode == 501 {
			return fail(5, "agent endpoint unavailable (HTTP %d)", resp.StatusCode)
		}
		return fail(5, "agent HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	var value any
	if len(b) > 0 {
		if e = json.Unmarshal(b, &value); e != nil {
			return fail(3, "agent returned invalid JSON")
		}
	}
	return a.emit(map[string]any{"status": resp.StatusCode, "response": value, "received_at": time.Now().UTC()})
}
