package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const version = "0.1.1"

type cliError struct {
	Code    int
	Message string
}

func (e *cliError) Error() string { return e.Message }
func fail(code int, format string, args ...any) error {
	return &cliError{code, fmt.Sprintf(format, args...)}
}

type options struct {
	JSON      bool
	DryRun    bool
	Device    string
	Baud      int
	Timeout   time.Duration
	Endpoint  string
	TokenFile string
}
type app struct {
	in       io.Reader
	out, err io.Writer
	opts     options
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	a := &app{in: os.Stdin, out: os.Stdout, err: os.Stderr, opts: options{
		Device: os.Getenv("RM500_AT_DEVICE"), Baud: 115200, Timeout: 30 * time.Second,
		Endpoint: os.Getenv("RM500_AGENT_URL"), TokenFile: os.Getenv("RM500_TOKEN_FILE"),
	}}
	err := a.run(ctx, os.Args[1:])
	if err != nil {
		os.Exit(a.report(err))
	}
}

func (a *app) report(err error) int {
	code := 1
	var ce *cliError
	if errors.As(err, &ce) {
		code = ce.Code
	}
	if errors.Is(err, context.Canceled) {
		code = 130
	}
	if errors.Is(err, context.DeadlineExceeded) {
		code = 4
	}
	if a.opts.JSON {
		_ = json.NewEncoder(a.err).Encode(map[string]any{"ok": false, "error": map[string]any{"code": code, "message": err.Error()}})
	} else {
		fmt.Fprintln(a.err, "error:", err)
	}
	return code
}

func (a *app) emit(v any) error {
	enc := json.NewEncoder(a.out)
	if !a.opts.JSON {
		enc.SetIndent("", "  ")
	}
	return enc.Encode(map[string]any{"ok": true, "data": v})
}

// All flags may precede or follow the command. No shell evaluation occurs.
func parseArgs(args []string) ([]string, map[string]string, error) {
	var words []string
	flags := map[string]string{}
	for i := 0; i < len(args); i++ {
		s := args[i]
		if s == "-h" {
			s = "--help"
		}
		if !strings.HasPrefix(s, "--") {
			words = append(words, s)
			continue
		}
		key, value, has := strings.Cut(strings.TrimPrefix(s, "--"), "=")
		if key == "" {
			return nil, nil, fail(2, "bare -- is not supported; use --flag=value")
		}
		if _, exists := flags[key]; exists {
			return nil, nil, fail(2, "duplicate flag --%s", key)
		}
		if !has {
			if key == "json" || key == "help" || key == "dry-run" {
				value = "true"
			} else {
				i++
				if i >= len(args) || strings.HasPrefix(args[i], "--") {
					return nil, nil, fail(2, "--%s needs a value", key)
				}
				value = args[i]
			}
		}
		flags[key] = value
	}
	return words, flags, nil
}

func (a *app) globals(f map[string]string) error {
	for k, v := range f {
		switch k {
		case "json", "dry-run":
			b, e := strconv.ParseBool(v)
			if e != nil {
				return fail(2, "--%s needs true/false", k)
			}
			if k == "json" {
				a.opts.JSON = b
			} else {
				a.opts.DryRun = b
			}
		case "at-device":
			a.opts.Device = v
		case "baud":
			n, e := strconv.Atoi(v)
			if e != nil || n <= 0 {
				return fail(2, "invalid baud")
			}
			a.opts.Baud = n
		case "timeout":
			d, e := time.ParseDuration(v)
			if e != nil || d <= 0 {
				return fail(2, "timeout must be a positive duration")
			}
			a.opts.Timeout = d
		case "endpoint":
			a.opts.Endpoint = v
		case "token-file":
			a.opts.TokenFile = v
		default:
			continue
		}
		delete(f, k)
	}
	return nil
}

func (a *app) run(ctx context.Context, args []string) error {
	// Preserve machine-readable errors even when argument parsing fails.
	for _, arg := range args {
		if arg == "--json" || arg == "--json=true" {
			a.opts.JSON = true
		}
	}
	words, f, err := parseArgs(args)
	if err != nil {
		return err
	}
	if err = a.globals(f); err != nil {
		return err
	}
	name := strings.Join(words, " ")
	if _, ok := f["help"]; ok {
		delete(f, "help")
		return a.help(name)
	}
	if name == "" {
		return a.help("")
	}
	if name == "help" {
		return a.help("")
	}
	if name == "version" {
		if len(f) > 0 {
			return fail(2, "version takes no flags")
		}
		return a.emit(map[string]string{"version": version})
	}
	if name == "schema" {
		if len(f) > 0 {
			return fail(2, "schema takes no flags")
		}
		return a.emit(map[string]any{"version": version, "commands": catalog(), "globals": globalHelp, "hardware_support": "firmware-dependent; schema is not a device capability assertion"})
	}
	if name == "repl" {
		if len(f) > 0 {
			return fail(2, "repl takes no flags")
		}
		return a.repl(ctx)
	}
	var cmd *command
	for _, c := range catalog() {
		if c.Name == name {
			cc := c
			cmd = &cc
			break
		}
	}
	if cmd == nil {
		return fail(2, "unknown command %q; use help or schema", name)
	}
	values, err := validateFlags(*cmd, f)
	if err != nil {
		return err
	}
	if a.opts.DryRun {
		return a.emit(map[string]any{"dry_run": true, "command": cmd.Name, "backend": cmd.Backend, "mutates": cmd.Mutates, "arguments": redact(values), "device": a.opts.Device})
	}
	switch cmd.Backend {
	case "at":
		return a.runAT(ctx, *cmd, values)
	case "local":
		return a.runLocal(ctx, *cmd, values)
	case "stream":
		return a.runStream(ctx, *cmd, values)
	case "agent":
		return a.runAgent(ctx, *cmd, values)
	default:
		return fail(2, "unsupported backend")
	}
}

const globalHelp = "--at-device PATH (RM500_AT_DEVICE), --baud 115200, --timeout 30s, --json, --dry-run, --endpoint URL (optional Agent only), --token-file PATH"

func (a *app) help(prefix string) error {
	if prefix == "schema" || prefix == "version" || prefix == "repl" || prefix == "help" {
		if a.opts.JSON {
			return a.emit(map[string]string{"command": prefix, "globals": globalHelp})
		}
		fmt.Fprintf(a.out, "rm500 %s\n%s\n", prefix, globalHelp)
		return nil
	}
	var cmds []command
	for _, c := range catalog() {
		if prefix == "" || c.Name == prefix || strings.HasPrefix(c.Name, prefix+" ") {
			cmds = append(cmds, c)
		}
	}
	if len(cmds) == 0 {
		return fail(2, "unknown command group %q", prefix)
	}
	if a.opts.JSON {
		return a.emit(map[string]any{"commands": cmds, "globals": globalHelp})
	}
	fmt.Fprintln(a.out, "rm500 — on-module Linux CLI (native AT + local data plane)")
	fmt.Fprintln(a.out, globalHelp)
	fmt.Fprintln(a.out, "Offline: help | schema --json | version | repl. Commands accept --help.")
	for _, c := range cmds {
		fmt.Fprintf(a.out, "\n%-26s [%s] %s\n", c.Name, c.Backend, c.Description)
		for _, p := range c.Params {
			mark := ""
			if p.Required {
				mark = " required"
			}
			fmt.Fprintf(a.out, "  --%s <%s>%s %s\n", p.Name, p.Type, mark, p.Description)
		}
	}
	return nil
}

func (a *app) repl(ctx context.Context) error {
	scanner := bufio.NewScanner(a.in)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	fmt.Fprintln(a.err, "rm500 REPL; help, schema, exit. No command history is saved.")
	for {
		fmt.Fprint(a.err, "rm500> ")
		if !scanner.Scan() {
			break
		}
		line := scanner.Text()
		if strings.TrimSpace(line) == "exit" || strings.TrimSpace(line) == "quit" {
			return nil
		}
		args, err := splitLine(line)
		if err == nil && len(args) > 0 {
			// Streaming stdin and nested REPLs would consume the command input.
			if args[0] == "repl" || args[0] == "stream" {
				err = fail(2, "run REPL/stream commands outside the REPL")
			} else {
				err = a.run(ctx, args)
			}
		}
		if err != nil {
			a.report(err)
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	return scanner.Err()
}

func splitLine(s string) ([]string, error) {
	var result []string
	var b strings.Builder
	var quote rune
	escape, started := false, false
	for _, r := range s {
		if escape {
			b.WriteRune(r)
			escape = false
			started = true
			continue
		}
		if r == '\\' && quote != '\'' {
			escape = true
			started = true
			continue
		}
		if quote != 0 {
			if r == quote {
				quote = 0
			} else {
				b.WriteRune(r)
			}
			continue
		}
		if r == '\'' || r == '"' {
			quote = r
			started = true
			continue
		}
		if r == ' ' || r == '\t' {
			if started {
				result = append(result, b.String())
				b.Reset()
				started = false
			}
			continue
		}
		b.WriteRune(r)
		started = true
	}
	if quote != 0 || escape {
		return nil, fail(2, "unterminated quote/escape")
	}
	if started {
		result = append(result, b.String())
	}
	return result, nil
}
