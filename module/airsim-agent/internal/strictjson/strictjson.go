// Package strictjson rejects ambiguous JSON before typed decoding.
package strictjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"unicode/utf8"
)

var ErrInvalid = errors.New("invalid_json")

func Object(data []byte, required, optional []string) (map[string]json.RawMessage, error) {
	if !utf8.Valid(data) {
		return nil, ErrInvalid
	}
	d := json.NewDecoder(bytes.NewReader(data))
	token, e := d.Token()
	if e != nil || token != json.Delim('{') {
		return nil, ErrInvalid
	}
	allowed := map[string]bool{}
	for _, k := range append(append([]string{}, required...), optional...) {
		allowed[k] = true
	}
	fields := map[string]json.RawMessage{}
	for d.More() {
		token, e = d.Token()
		if e != nil {
			return nil, ErrInvalid
		}
		key, ok := token.(string)
		if !ok || !allowed[key] || fields[key] != nil {
			return nil, ErrInvalid
		}
		var v json.RawMessage
		if d.Decode(&v) != nil || bytes.Equal(v, []byte("null")) {
			return nil, ErrInvalid
		}
		fields[key] = v
	}
	if _, e = d.Token(); e != nil {
		return nil, ErrInvalid
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return nil, ErrInvalid
	}
	for _, k := range required {
		if fields[k] == nil {
			return nil, ErrInvalid
		}
	}
	return fields, nil
}
func Decode(data []byte, required, optional []string, target any) error {
	if _, e := Object(data, required, optional); e != nil {
		return e
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if e := d.Decode(target); e != nil {
		return ErrInvalid
	}
	return nil
}
