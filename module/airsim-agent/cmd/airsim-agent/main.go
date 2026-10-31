package main

import (
	"airsim.local/airsim-agent/internal/at"
	"airsim.local/airsim-agent/internal/cloud"
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/identity"
	"airsim.local/airsim-agent/internal/journal"
	"airsim.local/airsim-agent/internal/media"
	"airsim.local/airsim-agent/internal/platform/atmodem"
	"airsim.local/airsim-agent/internal/platform/eg25"
	"airsim.local/airsim-agent/internal/platform/rm500u"
	"airsim.local/airsim-agent/internal/state"
	"airsim.local/airsim-agent/internal/transport/local"
	"context"
	"crypto/rand"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"syscall"
	"time"
)

const version = "2.0.0-dev.lc3"

func directory(path string) error {
	if e := os.MkdirAll(path, 0700); e != nil {
		return e
	}
	i, e := os.Lstat(path)
	if e != nil {
		return e
	}
	if !i.IsDir() || i.Mode().Perm() != 0700 {
		return errors.New("directory_permissions")
	}
	return nil
}
func run(ctx context.Context, profile, device, data, runDir, audioHelper, cloudConfig string, usbAddress ...string) error {
	var adapter platformAdapter
	switch profile {
	case rm500u.Profile:
		if err := rm500u.Validate(profile, device, runtime.GOOS, runtime.GOARCH); err != nil {
			return err
		}
		adapter = rm500u.New(nil)
		if data == "" {
			data = "/mnt/data/airsim-v2"
		}
	case eg25.Profile:
		if err := eg25.Validate(profile, device, runtime.GOOS, runtime.GOARCH); err != nil {
			return err
		}
		adapter = eg25.New(nil)
		if data == "" {
			data = "/usrdata/airsim-v2"
		}
		debug.SetMemoryLimit(6 << 20)
		debug.SetGCPercent(25)
	default:
		return errors.New("profile_mismatch")
	}
	if e := directory(data); e != nil {
		return e
	}
	persistent, e := at.Lock(filepath.Join(data, "instance.lock"))
	if e != nil {
		return e
	}
	defer persistent.Close()
	if e = directory(runDir); e != nil {
		return e
	}
	instance, e := at.Lock(filepath.Join(runDir, "instance.lock"))
	if e != nil {
		return e
	}
	defer instance.Close()
	id, e := identity.LoadOrCreate(filepath.Join(data, "config"))
	if e != nil {
		return e
	}
	boot, e := identity.UUID()
	if e != nil {
		return e
	}
	store := state.New(id.ModuleID, boot, profile)
	marker := filepath.Join(runDir, "at-inflight.json")
	var manager *at.Manager
	var lock *os.File
	if at.FencePresent(marker) {
		store.Commit(failedFields(adapter, "at_desynchronized"), false, "at_desynchronized")
	} else {
		port, l, openErr := at.OpenDevice(device)
		if openErr != nil {
			store.Commit(failedFields(adapter, "query_failed"), false, "query_failed")
		} else {
			lock = l
			defer lock.Close()
			manager = at.New(port, marker)
			defer manager.Close()
			activeManager := manager
			go func() {
				select {
				case <-ctx.Done():
					activeManager.Quiesce()
				case <-activeManager.Done():
				}
			}()
			adapter.SetAT(manager)
			verifyCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
			e = adapter.Verify(verifyCtx)
			cancel()
			if e != nil {
				store.Commit(failedFields(adapter, errorCode(e)), false, errorCode(e))
				manager.Close()
				manager = nil
			} else {
				fields := adapter.Sample(context.WithoutCancel(ctx))
				code := ""
				ok := true
				select {
				case <-manager.Done():
					ok = false
					code = "at_desynchronized"
				default:
				}
				store.Commit(fields, ok, code)
			}
		}
	}
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	pollDone := make(chan struct{})
	go func() {
		defer close(pollDone)
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		var events, overflow, broken <-chan struct{}
		if manager != nil {
			events = manager.Events()
			overflow = manager.Overflow()
			broken = manager.Done()
		}
		for {
			select {
			case <-child.Done():
				return
			case <-events:
			case <-overflow:
				store.Invalidate("query_failed")
			case <-broken:
				store.Invalidate("at_desynchronized")
				broken = nil
			case <-ticker.C:
				if manager == nil {
					continue
				}
				select {
				case <-manager.Done():
					continue
				default:
				}
				fields := adapter.Sample(context.WithoutCancel(child))
				ok := true
				code := ""
				select {
				case <-manager.Done():
					ok = false
					code = "at_desynchronized"
				default:
				}
				store.Commit(fields, ok, code)
			}
		}
	}()
	commands, journalErr := journal.Open(filepath.Join(data, "state"))
	coordinator := control.New(boot, id.CommandDigest, func() bool { _, ready := store.View(time.Now()); return ready.Ready }, commands, journalErr)
	if profile == eg25.Profile {
		smsLedger := eg25.OpenSMSLedger(filepath.Join(data, "state", "eg25-sms-seen"))
		go coordinator.RunWithBackend(child, func(ctx context.Context) (hal.ControlSession, error) {
			if manager == nil {
				return nil, errors.New("backend_unavailable")
			}
			s, err := eg25.Connect(ctx, manager, smsLedger)
			if err != nil {
				return nil, err
			}
			return s, nil
		})
	} else {
		go coordinator.Run(child)
	}
	audio := media.New(coordinator, audioHelper, filepath.Join(runDir, "media.sock"), profile)
	go audio.Serve(child)
	if cloudConfig == "" {
		cloudConfig = filepath.Join(data, "config", "cloud.json")
	}
	provisioner := cloud.NewProvisioner(id, cloudConfig, profile)
	cloudAgent := &cloud.Agent{P: provisioner, Control: coordinator, Media: audio, Signal: store, Boot: boot, Version: version}
	if len(usbAddress) > 0 {
		if e = cloudAgent.ConfigureUSB(usbAddress[0], filepath.Join(data, "config")); e != nil {
			return e
		}
	}
	cloudDone := make(chan struct{})
	go func() { defer close(cloudDone); cloudAgent.Run(child) }()
	e = local.Serve(ctx, filepath.Join(runDir, "control.sock"), cloud.WithLocal(local.WithAudio(local.Handler(store, version, boot, coordinator), audio), provisioner, cloudAgent))
	cancel()
	if manager != nil {
		manager.GracefulClose()
	}
	<-pollDone
	<-coordinator.Done()
	audio.Close()
	<-cloudDone
	return e
}
func errorCode(e error) string {
	if errors.Is(e, at.ErrDesynchronized) {
		return "at_desynchronized"
	}
	if e.Error() == "profile_mismatch" {
		return "profile_mismatch"
	}
	return "query_failed"
}

func useEarlyLinuxRandom() (*os.File, error) {
	f, e := os.Open("/dev/urandom")
	if e != nil {
		return nil, e
	}
	rand.Reader = f
	return f, nil
}

func main() {
	profile := flag.String("profile", "", "explicit platform profile")
	device := flag.String("at-device", "", "explicit AT device")
	data := flag.String("data-dir", "", "persistent directory")
	runDir := flag.String("runtime-dir", "/run/airsim-v2", "runtime directory")
	audioHelper := flag.String("audio-helper", "", "explicit native audio helper executable")
	usbAddress := flag.String("usb-listen", "", "USB private IPv4 TLS listen address")
	cloudConfig := flag.String("cloud-config", "", "explicit secure cloud configuration file")
	waitRandom := flag.Bool("wait-random", false, "wait until the kernel random source is initialized")
	flag.Parse()
	if *waitRandom {
		var probe [32]byte
		if _, e := rand.Read(probe[:]); e != nil {
			fmt.Fprintln(os.Stderr, "airsim-agent:", e)
			os.Exit(1)
		}
		return
	}
	randomDevice, e := useEarlyLinuxRandom()
	if e != nil {
		fmt.Fprintln(os.Stderr, "airsim-agent:", e)
		os.Exit(1)
	}
	defer randomDevice.Close()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() {
		<-ctx.Done()
		timer := time.NewTimer(15 * time.Second)
		defer timer.Stop()
		<-timer.C
		os.Exit(1)
	}()
	if e := run(ctx, *profile, *device, *data, *runDir, *audioHelper, *cloudConfig, *usbAddress); e != nil {
		fmt.Fprintln(os.Stderr, "airsim-agent:", e)
		os.Exit(1)
	}
}

var _ hal.Telephony = (*rm500u.Adapter)(nil)
var _ hal.RadioSIM = (*rm500u.Adapter)(nil)
var _ hal.Network = (*rm500u.Adapter)(nil)
var _ hal.Platform = (*rm500u.Adapter)(nil)
var _ hal.Audio = (*rm500u.Adapter)(nil)
var _ hal.Messaging = (*rm500u.Adapter)(nil)

type platformAdapter interface {
	SetAT(atmodem.Querier)
	Verify(context.Context) error
	Sample(context.Context) map[string]hal.Field
	Network() hal.Field
	Platform() hal.Field
}

func failedFields(adapter platformAdapter, code string) map[string]hal.Field {
	fields := map[string]hal.Field{}
	for _, name := range []string{"sim", "signal", "registration", "ims", "calls"} {
		fields[name] = hal.Unavailable("at", code)
	}
	fields["network"] = adapter.Network()
	fields["platform"] = adapter.Platform()
	return fields
}
