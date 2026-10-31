package wire

import (
	"encoding/json"
	"testing"
)

func TestStrict(t *testing.T) {
	for _, s := range []string{`{"a":1,"a":2}`, `{"a":null}`, `{"a":1} {}`, `{"a":1,"b":2}`, `{}`, `{"a":"1"}`} {
		var v struct {
			A int `json:"a"`
		}
		if Decode([]byte(s), &v, "a") == nil {
			t.Fatalf("accepted invalid input")
		}
	}
	var v struct {
		A int `json:"a"`
	}
	if Decode([]byte(`{"a":1}`), &v, "a") != nil {
		t.Fatal("valid rejected")
	}
}
func TestNestedExactAndNull(t *testing.T) {
	type inner struct {
		Ready bool `json:"ready"`
	}
	var v struct {
		Inner inner `json:"inner"`
	}
	for _, s := range []string{`{"inner":{}}`, `{"inner":{"READY":true}}`, `{"inner":{"ready":true,"extra":1}}`} {
		if Decode([]byte(s), &v) == nil {
			t.Fatal("accepted incomplete or unknown nested field")
		}
	}
	var r struct {
		ID      string          `json:"command_id"`
		Status  int             `json:"status_code"`
		Receipt json.RawMessage `json:"receipt"`
	}
	if DecodeNullable([]byte("{\"command_id\":\"x\",\"status_code\":400,\"receipt\" : \n null}"), &r, "receipt") != nil {
		t.Fatal("explicit null receipt rejected")
	}
}

func TestNullableRequiredFields(t *testing.T) {
	var receipt struct {
		ID      string          `json:"command_id"`
		Status  int             `json:"status_code"`
		Receipt json.RawMessage `json:"receipt"`
	}
	for _, input := range []string{`{"status_code":503,"receipt":null}`, `{"command_id":"x","receipt":null}`, `{"command_id":"x","status_code":503}`} {
		if DecodeNullable([]byte(input), &receipt, "receipt") == nil {
			t.Fatal("accepted missing receipt field")
		}
	}
	var authorization struct {
		Request       string          `json:"request_id"`
		Status        int             `json:"status_code"`
		Authorization json.RawMessage `json:"authorization"`
	}
	if DecodeNullable([]byte(`{"request_id":"x","status_code":503,"authorization":null}`), &authorization, "authorization") != nil {
		t.Fatal("valid nullable authorization rejected")
	}
}

func TestNullableObjectPaths(t *testing.T) {
	var v struct {
		Signal json.RawMessage `json:"signal,omitempty"`
		Other  json.RawMessage `json:"other,omitempty"`
	}
	for _, input := range []string{`{"signal":{"rssi":null}}`, `{"signal":null}`, `{}`} {
		if DecodeNullable([]byte(input), &v, "signal", "signal.rssi") != nil {
			t.Fatalf("rejected %s", input)
		}
	}
	for _, input := range []string{`{"other":{"rssi":null}}`, `{"signal":{"unknown":null}}`, `{"signal":{"nested":{"rssi":null}}}`} {
		if DecodeNullable([]byte(input), &v, "signal", "signal.rssi") == nil {
			t.Fatalf("accepted %s", input)
		}
	}
}
