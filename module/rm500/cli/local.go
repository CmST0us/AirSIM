package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

func readText(path string) string {
	b, e := os.ReadFile(path)
	if e != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}
func inventory(patterns ...string) []string {
	out := []string{}
	for _, p := range patterns {
		m, _ := filepath.Glob(p)
		out = append(out, m...)
	}
	return out
}
func interfaces() ([]map[string]any, error) {
	list, e := net.Interfaces()
	if e != nil {
		return nil, e
	}
	out := []map[string]any{}
	for _, i := range list {
		addrs, e := i.Addrs()
		if e != nil {
			return nil, e
		}
		as := []string{}
		for _, v := range addrs {
			as = append(as, v.String())
		}
		row := map[string]any{"name": i.Name, "mtu": i.MTU, "flags": i.Flags.String(), "addresses": as}
		stats := map[string]uint64{}
		for _, s := range []string{"rx_bytes", "tx_bytes", "rx_packets", "tx_packets", "rx_errors", "tx_errors", "rx_dropped", "tx_dropped"} {
			value, e := strconv.ParseUint(readText(filepath.Join("/sys/class/net", i.Name, "statistics", s)), 10, 64)
			if e == nil {
				stats[s] = value
			}
		}
		row["statistics"] = stats
		row["carrier"] = readText(filepath.Join("/sys/class/net", i.Name, "carrier"))
		out = append(out, row)
	}
	return out, nil
}
func (a *app) execute(ctx context.Context, tool string, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, a.opts.Timeout)
	defer cancel()
	path, e := exec.LookPath(tool)
	if e != nil {
		return fail(3, "required system tool %s is not installed", tool)
	}
	out, e := exec.CommandContext(ctx, path, args...).CombinedOutput()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if e != nil || (tool == "tinyplay" && audioToolFailed(string(out))) {
		return fail(5, "%s failed: %s", tool, strings.TrimSpace(string(out)))
	}
	return a.emit(map[string]any{"tool": tool, "output": string(out)})
}
func (a *app) runLocal(ctx context.Context, c command, v map[string]string) error {
	switch c.Name {
	case "system info":
		return a.emit(map[string]any{"os": runtime.GOOS, "arch": runtime.GOARCH, "kernel": readText("/proc/sys/kernel/osrelease"), "distribution": readText("/etc/os-release"), "uptime": readText("/proc/uptime"), "memory": readText("/proc/meminfo")})
	case "system capabilities":
		found := map[string]string{}
		for _, t := range []string{"ip", "ping", "tinymix", "tinycap", "tinyplay", "tinypcminfo", "iptables", "connmanctl", "quec-voice", "atrouter"} {
			if p, e := exec.LookPath(t); e == nil {
				found[t] = p
			}
		}
		is, e := interfaces()
		if e != nil {
			return e
		}
		return a.emit(map[string]any{"at_candidates": inventory("/dev/smd*", "/dev/stty_lte*", "/dev/ttyUSB*"), "configured_at_device": a.opts.Device, "interfaces": is, "sound_devices": inventory("/dev/snd/*"), "tools": found, "note": "Inventory only; candidate AT channels may be owned by RIL/atrouter. No functional support is inferred."})
	case "system power":
		sensors := map[string]string{}
		for _, p := range inventory("/sys/class/power_supply/*/uevent", "/sys/class/thermal/thermal_zone*/temp", "/sys/class/thermal/thermal_zone*/type") {
			sensors[p] = readText(p)
		}
		return a.emit(map[string]any{"available": len(sensors) > 0, "sensors": sensors})
	case "network interfaces":
		is, e := interfaces()
		if e != nil {
			return e
		}
		return a.emit(is)
	case "network routes":
		return a.execute(ctx, "ip", "-"+v["family"], "route", "show", "table", "all")
	case "network link-set":
		return a.execute(ctx, "ip", "link", "set", "dev", v["interface"], v["state"])
	case "network address-add", "network address-delete":
		verb := "add"
		if c.Name == "network address-delete" {
			verb = "del"
		}
		return a.execute(ctx, "ip", "addr", verb, v["cidr"], "dev", v["interface"])
	case "network route-replace":
		return a.execute(ctx, "ip", "route", "replace", v["destination"], "via", v["gateway"], "dev", v["interface"])
	case "network dns":
		ctx, cancel := context.WithTimeout(ctx, a.opts.Timeout)
		defer cancel()
		ips, e := net.DefaultResolver.LookupHost(ctx, v["host"])
		if e != nil {
			return fail(3, "DNS lookup failed: %v", e)
		}
		return a.emit(map[string]any{"addresses": ips})
	case "network ping":
		count := v["count"]
		if count == "" {
			count = "4"
		}
		args := []string{"-c", count}
		if v["interface"] != "" {
			args = append(args, "-I", v["interface"])
		}
		return a.execute(ctx, "ping", append(args, v["host"])...)
	case "usb status":
		files := map[string]string{}
		for _, p := range inventory("/sys/class/android_usb/android0/functions", "/sys/class/android_usb/android0/idVendor", "/sys/class/android_usb/android0/idProduct", "/sys/kernel/config/usb_gadget/*/UDC", "/sys/kernel/config/usb_gadget/*/idVendor", "/sys/kernel/config/usb_gadget/*/idProduct") {
			files[p] = readText(p)
		}
		return a.emit(map[string]any{"descriptors": files, "configfs_functions": inventory("/sys/kernel/config/usb_gadget/*/configs/*/*"), "udc": inventory("/sys/class/udc/*")})
	case "audio devices":
		return a.emit(map[string]any{"cards": readText("/proc/asound/cards"), "pcm": readText("/proc/asound/pcm"), "nodes": inventory("/dev/snd/*"), "note": "PCM nodes do not prove a working modem voice route"})
	case "audio mixer":
		return a.execute(ctx, "tinymix")
	case "audio mixer-set":
		return a.execute(ctx, "tinymix", v["control"], v["value"])
	case "audio pcm-info":
		return a.execute(ctx, "tinypcminfo", "-D", v["card"], "-d", v["device"])
	case "audio play":
		path, e := filepath.Abs(v["file"])
		if e != nil {
			return e
		}
		return a.execute(ctx, "tinyplay", path, "-D", v["card"], "-d", v["device"])
	case "audio probe", "audio tone":
		return a.runAudio(ctx, c.Name, v)
	case "watch interfaces":
		a.opts.JSON = true
		interval := time.Second
		if v["interval"] != "" {
			interval, _ = positiveDuration(v["interval"])
		}
		count := 0
		if v["count"] != "" {
			count, _ = strconv.Atoi(v["count"])
		}
		for n := 0; count == 0 || n < count; n++ {
			is, e := interfaces()
			if e != nil {
				return e
			}
			if e = a.emit(map[string]any{"sampled_at": time.Now().UTC(), "interfaces": is}); e != nil {
				return e
			}
			if n+1 == count {
				return nil
			}
			if e = pause(ctx, interval); e != nil {
				return e
			}
		}
		return nil
	}
	return fmt.Errorf("local command not implemented: %s", c.Name)
}
