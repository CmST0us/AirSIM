package wire

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"reflect"
	"regexp"
	"strings"
	"unicode/utf8"
)

var ErrInvalid = errors.New("invalid_parameters")
var UUID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
var Hex = regexp.MustCompile(`^[0-9a-f]{64}$`)

func ID() string {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	b[6] = b[6]&15 | 64
	b[8] = b[8]&63 | 128
	h := hex.EncodeToString(b)
	return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}
func Token() string {
	b := make([]byte, 32)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)
}
func Hash(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

// Walk every object before typed decoding to reject duplicate keys at any depth.
func walk(d *json.Decoder) error { return walkValue(d, false, nil) }
func walkValue(d *json.Decoder, allow bool, fields map[string]bool) error {
	t, e := d.Token()
	if e != nil {
		return ErrInvalid
	}
	if t == nil {
		if allow {
			return nil
		}
		return ErrInvalid
	}
	switch t {
	case json.Delim('{'):
		seen := map[string]bool{}
		for d.More() {
			k, e := d.Token()
			if e != nil {
				return ErrInvalid
			}
			s, ok := k.(string)
			if !ok || seen[s] {
				return ErrInvalid
			}
			seen[s] = true
			if e = walkValue(d, fields[s] || s == "receipt", nil); e != nil {
				return e
			}
		}
		_, e = d.Token()
		return e
	case json.Delim('['):
		for d.More() {
			if e = walk(d); e != nil {
				return e
			}
		}
		_, e = d.Token()
		return e
	}
	return nil
}
func Decode(b []byte, v any, required ...string) error {
	if !utf8.Valid(b) {
		return ErrInvalid
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	if walk(d) != nil {
		return ErrInvalid
	}
	if _, e := d.Token(); e != io.EOF {
		return ErrInvalid
	}
	if len(required) > 0 {
		var m map[string]json.RawMessage
		if json.Unmarshal(b, &m) != nil {
			return ErrInvalid
		}
		for _, k := range required {
			if _, ok := m[k]; !ok {
				return ErrInvalid
			}
		}
	}
	if exactShape(b, reflect.TypeOf(v)) != nil {
		return ErrInvalid
	}
	d = json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(v) != nil {
		return ErrInvalid
	}
	return nil
}
func Body(w http.ResponseWriter, r *http.Request, v any, limit int64, required ...string) error {
	if r.Header.Get("Content-Type") != "application/json" {
		return ErrInvalid
	}
	b, e := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	if e != nil {
		return ErrInvalid
	}
	return Decode(b, v, required...)
}
func JSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func Error(w http.ResponseWriter, status int, code string) {
	JSON(w, status, map[string]string{"error": code})
}

// DecodeNullable permits explicit null only in named top-level fields.
func DecodeNullable(b []byte, v any, nullable ...string) error {
	allowed := map[string]bool{}
	for _, k := range nullable {
		allowed[k] = true
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	if walkValue(d, false, allowed) != nil {
		return ErrInvalid
	}
	if _, e := d.Token(); e != io.EOF {
		return ErrInvalid
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(b, &fields) != nil {
		return ErrInvalid
	}
	for _, k := range []string{"command_id", "status_code", "receipt"} {
		if _, ok := fields[k]; !ok {
			return ErrInvalid
		}
	}
	if exactShape(b, reflect.TypeOf(v)) != nil {
		return ErrInvalid
	}
	d = json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(v) != nil {
		return ErrInvalid
	}
	return nil
}

// exactShape enforces required fields and exact case at every typed object.
func exactShape(b []byte, t reflect.Type) error {
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == reflect.TypeOf(json.RawMessage{}) {
		return nil
	}
	if t.PkgPath() == "time" {
		var timestamp string
		if json.Unmarshal(b, &timestamp) != nil || !strings.HasSuffix(timestamp, "Z") {
			return ErrInvalid
		}
		return nil
	}
	switch t.Kind() {
	case reflect.Struct:
		var fields map[string]json.RawMessage
		if json.Unmarshal(b, &fields) != nil || fields == nil {
			return ErrInvalid
		}
		known := map[string]bool{}
		for i := 0; i < t.NumField(); i++ {
			f := t.Field(i)
			tag := strings.Split(f.Tag.Get("json"), ",")
			if tag[0] == "-" {
				continue
			}
			name := tag[0]
			if name == "" {
				name = f.Name
			}
			known[name] = true
			raw, ok := fields[name]
			optional := len(tag) > 1 && tag[1] == "omitempty"
			if !ok {
				if !optional {
					return ErrInvalid
				}
				continue
			}
			if name == "receipt" && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
				continue
			}
			if exactShape(raw, f.Type) != nil {
				return ErrInvalid
			}
		}
		for k := range fields {
			if !known[k] {
				return ErrInvalid
			}
		}
	case reflect.Slice, reflect.Array:
		if t.Elem().Kind() == reflect.Uint8 {
			return nil
		}
		var items []json.RawMessage
		if json.Unmarshal(b, &items) != nil {
			return ErrInvalid
		}
		for _, raw := range items {
			if exactShape(raw, t.Elem()) != nil {
				return ErrInvalid
			}
		}
	}
	return nil
}
