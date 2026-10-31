package eg25

import (
	"encoding/hex"
	"fmt"
	"github.com/warthog618/sms"
	"strings"
	"testing"
)

func TestIncomingPDUAndMultipart(t *testing.T) {
	for _, body := range []string{"hello @ world", "你好，模块", strings.Repeat("中文消息", 40)} {
		parts, err := sms.Encode([]byte(body), sms.AsDeliver, sms.From("+12345678901"))
		if err != nil {
			t.Fatal(err)
		}
		var lines []string
		for i, p := range parts {
			b, err := p.MarshalBinary()
			if err != nil {
				t.Fatal(err)
			}
			lines = append(lines, fmt.Sprintf("+CMGL: %d,0,,%d", i+1, len(b)), "00"+hex.EncodeToString(b))
		}
		got, err := decodeSMS(lines)
		if err != nil || len(got) != 1 || got[0].text != body || got[0].sender != "+12345678901" {
			t.Fatalf("decode failed: %v", err)
		}
	}
	if got, err := decodeSMS([]string{"+CMGL: 1,0,,7", "FF00"}); err != nil || len(got) != 0 {
		t.Fatal("truncated SMSC must be skipped without failing the list")
	}
	parts, err := sms.Encode([]byte("after"), sms.AsDeliver, sms.From("+12345678901"))
	if err != nil {
		t.Fatal(err)
	}
	b, err := parts[0].MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	got, err := decodeSMS([]string{"+CMGL: 1,0,,3", "000400", "+CMGL: 2,0,,1", "00" + hex.EncodeToString(b)})
	if err != nil || len(got) != 1 || got[0].text != "after" {
		t.Fatalf("undecodable PDU blocked later messages: %v", err)
	}
	if _, err := decodeSMS([]string{"+CMGL: 1,0,,1", "zz"}); err == nil {
		t.Fatal("accepted non-hex PDU line")
	}
}
