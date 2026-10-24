package control

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func testRequest() Request {
	return Request{CommandID: "a1111111-1111-4111-8111-111111111111", BootID: "b1111111-1111-4111-8111-111111111111", Epoch: "c1111111-1111-4111-8111-111111111111", Deadline: time.Now().Add(30 * time.Second).UTC().Format(time.RFC3339Nano), Action: "sms.send", Args: Args{Number: "+12025550123", Text: "synthetic"}}
}
func TestStrictCommand(t *testing.T) {
	r := testRequest()
	b := r.Canonical()
	if _, e := Parse(b); e != nil {
		t.Fatal(e)
	}
	for _, s := range []string{strings.Replace(string(b), `"command_id"`, `"Command_ID"`, 1), strings.Replace(string(b), `"action":"sms.send"`, `"action":"sms.send","action":"sms.send"`, 1), string(b) + `{}`, strings.Replace(string(b), `"text":"synthetic"`, `"text":"synthetic","extra":1`, 1), strings.Replace(string(b), `"text":"synthetic"`, `"text":null`, 1)} {
		if _, e := Parse([]byte(s)); e == nil {
			t.Fatal("accepted ambiguous JSON")
		}
	}
}
func TestNumbersAndSMSBudget(t *testing.T) {
	for _, n := range []string{"*123#", "123456", "+12025550123;", " +12025550123", "1202555012345678"} {
		r := testRequest()
		r.Args.Number = n
		if _, e := Parse(r.Canonical()); e == nil {
			t.Fatal("accepted invalid number")
		}
	}
	for _, text := range []string{"", strings.Repeat("x", 71), strings.Repeat("😀", 36), "a\x00b"} {
		r := testRequest()
		r.Args.Text = text
		b, _ := json.Marshal(r)
		if _, e := Parse(b); e == nil {
			t.Fatal("accepted invalid text")
		}
	}
	r := testRequest()
	r.Args.Text = strings.Repeat("😀", 35)
	if _, e := Parse(r.Canonical()); e != nil {
		t.Fatal(e)
	}
}
func TestDeadlineBudget(t *testing.T) {
	r := testRequest()
	now := time.Now()
	if _, ok := r.Budget(now); !ok {
		t.Fatal("valid deadline rejected")
	}
	for _, delta := range []time.Duration{-time.Second, 61 * time.Second} {
		r.Deadline = now.Add(delta).Format(time.RFC3339Nano)
		if _, ok := r.Budget(now); ok {
			t.Fatal("invalid deadline accepted")
		}
	}
}
