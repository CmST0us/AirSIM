package control

import (
	"airsim.local/server/internal/wire"
	"encoding/json"
	"testing"
	"time"
)

func TestSixDigitNumberContract(t *testing.T) {
	valid := []string{"123456", "012345", "+123456", "1234567", "+12025550123", "123456789012345", "+123456789012345"}
	invalid := []string{"", "12345", "+12345", "1234567890123456", "１２３４５６", "123 456", "123-456", "123456\n", "123456\r", "123456;", "*123456#", "123456+", "++123456"}
	for _, action := range []string{"call.dial", "sms.send"} {
		for _, accepted := range []bool{true, false} {
			numbers := invalid
			if accepted {
				numbers = valid
			}
			for _, n := range numbers {
				args := Args{Number: n}
				if action == "sms.send" {
					args.Text = "synthetic"
				}
				argsJSON, err := json.Marshal(args)
				if err != nil {
					t.Fatal(err)
				}
				r := Request{ID: wire.ID(), Boot: wire.ID(), Backend: wire.ID(), Deadline: time.Now().Add(45 * time.Second).UTC().Format(time.RFC3339Nano), Action: action, Args: argsJSON}
				data, err := json.Marshal(r)
				if err != nil {
					t.Fatal(err)
				}
				forwarded, got, err := parse(data)
				if (err == nil) != accepted {
					t.Fatalf("%s number %q: accepted = %v, want %v", action, n, err == nil, accepted)
				}
				if accepted {
					var forwardedArgs Args
					if json.Unmarshal(forwarded.Args, &forwardedArgs) != nil || got.Number != n || forwardedArgs.Number != n {
						t.Fatal("number changed before forwarding to Agent")
					}
				}
			}
		}
	}
}
