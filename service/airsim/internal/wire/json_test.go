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
