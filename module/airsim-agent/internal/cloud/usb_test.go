package cloud

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"airsim.local/airsim-agent/internal/control"
)

func usbFixture(t *testing.T) (*Agent, *USBAuthorization, string) {
	t.Helper()
	f := newFixture(t)
	a := &Agent{P: f.p, Control: &fakeControl{boot: uid(), epoch: uid(), call: uid(), commands: map[string]control.Request{}}, Media: &fakeMedia{}, owners: map[string]owner{}}
	dir := t.TempDir()
	if e := a.ConfigureUSB("192.168.225.1:8577", dir); e != nil {
		t.Fatal(e)
	}
	grant, e := a.USB.authorize(uid(), time.Now().Add(24*time.Hour).UTC().Format(time.RFC3339))
	if e != nil {
		t.Fatal(e)
	}
	return a, grant, dir
}
func signedUSB(t *testing.T, g *USBAuthorization, method, path string, body []byte, nonce string) *http.Request {
	t.Helper()
	r := httptest.NewRequest(method, g.Origin+path, bytes.NewReader(body))
	stamp := strconv.FormatInt(time.Now().Unix(), 10)
	key, _ := hex.DecodeString(g.Token)
	h := hmac.New(sha256.New, key)
	h.Write([]byte(stamp + "\n" + nonce + "\n" + method + "\n" + path + "\n"))
	h.Write(body)
	r.Header.Set("Authorization", "Bearer "+g.Token)
	r.Header.Set("X-AirSIM-Timestamp", stamp)
	r.Header.Set("X-AirSIM-Nonce", nonce)
	r.Header.Set("X-AirSIM-Signature", hex.EncodeToString(h.Sum(nil)))
	return r
}
func TestUSBAuthenticationAndWhitelist(t *testing.T) {
	a, g, _ := usbFixture(t)
	nonce := strings.Repeat("a", 64)
	r := signedUSB(t, g, "GET", "/v2/modules", nil, nonce)
	w := httptest.NewRecorder()
	a.USB.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatal(w.Code)
	}
	w = httptest.NewRecorder()
	a.USB.ServeHTTP(w, signedUSB(t, g, "GET", "/v2/modules", nil, nonce))
	if w.Code != 401 {
		t.Fatal("replay", w.Code)
	}
	r = signedUSB(t, g, "POST", "/v2/local/cloud/activate", []byte("{}"), strings.Repeat("b", 64))
	w = httptest.NewRecorder()
	a.USB.ServeHTTP(w, r)
	if w.Code != 404 {
		t.Fatal("management route", w.Code)
	}
	r = signedUSB(t, g, "GET", "/v2/modules", nil, strings.Repeat("c", 64))
	r.Header.Set("X-AirSIM-Signature", strings.Repeat("0", 64))
	w = httptest.NewRecorder()
	a.USB.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("signature", w.Code)
	}
	if e := a.USB.revoke(g.Client); e != nil {
		t.Fatal(e)
	}
	w = httptest.NewRecorder()
	a.USB.ServeHTTP(w, signedUSB(t, g, "GET", "/v2/modules", nil, strings.Repeat("d", 64)))
	if w.Code != 401 {
		t.Fatal("revoked", w.Code)
	}
}
func TestUSBGrantAndCommandMetadataSurviveRestart(t *testing.T) {
	a, g, dir := usbFixture(t)
	fc := a.Control.(*fakeControl)
	req := control.Request{CommandID: uid(), BootID: fc.boot, Epoch: fc.epoch, Deadline: time.Now().Add(45 * time.Second).UTC().Format(time.RFC3339), Action: "sms.send", Args: control.Args{Number: "+15550000000", Text: "private-body"}}
	data, _ := json.Marshal(map[string]any{"connection_epoch": a.USB.epoch, "command": req})
	path := "/v2/modules/" + a.P.id.ModuleID + "/commands"
	w := httptest.NewRecorder()
	a.USB.ServeHTTP(w, signedUSB(t, g, "POST", path, data, strings.Repeat("e", 64)))
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	disk, e := os.ReadFile(filepath.Join(dir, "usb-commands.json"))
	if e != nil {
		t.Fatal(e)
	}
	if bytes.Contains(disk, []byte(req.Args.Text)) || bytes.Contains(disk, []byte(req.Args.Number)) {
		t.Fatal("sensitive command persisted")
	}
	old := a.USB.records[req.CommandID]
	b := &Agent{P: a.P, Control: fc, Media: a.Media, owners: map[string]owner{}}
	if e = b.ConfigureUSB("192.168.225.1:8577", dir); e != nil {
		t.Fatal(e)
	}
	if b.USB.grants[g.Client].Token != g.Token || !bytes.Equal(a.USB.certificate.Certificate[0], b.USB.certificate.Certificate[0]) {
		t.Fatal("identity lost")
	}
	w = httptest.NewRecorder()
	b.USB.ServeHTTP(w, signedUSB(t, g, "GET", path+"/"+req.CommandID, nil, strings.Repeat("f", 64)))
	if w.Code != 200 {
		t.Fatal(w.Code)
	}
	var record struct {
		Generation string `json:"generation"`
	}
	if json.Unmarshal(w.Body.Bytes(), &record) != nil || record.Generation != old.Generation || fc.submitted.Load() != 1 {
		t.Fatal("result recovery")
	}
}

type endedControl struct{ *fakeControl }

func (e endedControl) View(ctx context.Context, kind, id string) (any, int) {
	if kind == "calls" {
		return control.CallsView{Boot: e.boot, Epoch: e.epoch, Calls: []control.Call{{ID: e.call, State: "disconnected"}}}, 200
	}
	return e.fakeControl.View(ctx, kind, id)
}
func TestUSBCloudOwnerAndShortCallRelease(t *testing.T) {
	a, g, _ := usbFixture(t)
	fc := a.Control.(*fakeControl)
	req := control.Request{CommandID: uid(), BootID: fc.boot, Epoch: fc.epoch, Action: "call.answer", Args: control.Args{CallID: fc.call}}
	if !a.reserveCommand(context.Background(), req, g.Client, "usb") {
		t.Fatal("reserve")
	}
	if a.reserveCommand(context.Background(), req, g.Client, "cloud") {
		t.Fatal("cloud stole USB call")
	}
	a.Control = endedControl{fc}
	next := req
	next.CommandID = uid()
	next.Action = "call.dial"
	next.Args = control.Args{Number: "+15550000000"}
	if !a.reserveCommand(context.Background(), next, g.Client, "usb") {
		t.Fatal("ended call retained")
	}
}
func TestUSBExpiryAndClientReplacement(t *testing.T) {
	a, g, _ := usbFixture(t)
	if _, e := a.USB.authorize(uid(), time.Now().Add(25*time.Hour).UTC().Format(time.RFC3339)); e == nil {
		t.Fatal("unbounded grant")
	}
	if _, e := a.USB.authorize(uid(), time.Now().Add(time.Hour).UTC().Format(time.RFC3339)); e != nil {
		t.Fatal(e)
	}
	if len(a.USB.grants) != 1 {
		t.Fatal("multiple owners")
	}
	r := signedUSB(t, g, "GET", "/v2/modules", nil, strings.Repeat("a", 64))
	if a.USB.client(r) != "" {
		t.Fatal("old client accepted")
	}
}
func TestUSBBodySignatureIncludesContent(t *testing.T) {
	a, g, _ := usbFixture(t)
	r := signedUSB(t, g, "POST", "/v2/modules", []byte("{}"), strings.Repeat("a", 64))
	r.Body = io.NopCloser(strings.NewReader("{\"changed\":true}"))
	if a.USB.client(r) != "" {
		t.Fatal("modified body accepted")
	}
}

func TestUSBRegenerates1990ExpiredCertificate(t *testing.T) {
	f := newFixture(t)
	dir := t.TempDir()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: f.p.id.ModuleID},
		NotBefore:    time.Date(1980, 1, 5, 23, 55, 0, 0, time.UTC),
		NotAfter:     time.Date(1990, 1, 6, 0, 0, 0, 0, time.UTC),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{net.ParseIP("192.168.225.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatal(err)
	}
	key, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	oldPEM := append(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})...)
	if err := os.WriteFile(filepath.Join(dir, "usb-tls.pem"), oldPEM, 0600); err != nil {
		t.Fatal(err)
	}
	a := &Agent{P: f.p, Control: &fakeControl{boot: uid(), epoch: uid(), call: uid(), commands: map[string]control.Request{}}, Media: &fakeMedia{}, owners: map[string]owner{}}
	if err := a.ConfigureUSB("192.168.225.1:8577", dir); err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(a.USB.certificate.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if !time.Now().Before(leaf.NotAfter) {
		t.Fatalf("expected expired 1990 usb-tls.pem to be regenerated, still expires %v", leaf.NotAfter)
	}
}
