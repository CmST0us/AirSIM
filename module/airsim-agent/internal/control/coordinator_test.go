package control

import (
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/identity"
	"airsim.local/airsim-agent/internal/journal"
	"airsim.local/airsim-agent/internal/ofono"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/godbus/dbus/v5"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeBackend struct {
	count  atomic.Int32
	result hal.WriteResult
}

func (f *fakeBackend) Snapshot(context.Context) (hal.ControlSnapshot, error) {
	return hal.ControlSnapshot{}, nil
}
func (f *fakeBackend) Execute(context.Context, hal.WriteAction) hal.WriteResult {
	f.count.Add(1)
	return f.result
}
func newCoordinator(t *testing.T) (*Coordinator, *fakeBackend, string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "state")
	store, e := journal.Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	boot, _ := identity.UUID()
	epoch, _ := identity.UUID()
	c := New(boot, func(b []byte) string { x := sha256.Sum256(b); return hex.EncodeToString(x[:]) }, func() bool { return true }, store, nil)
	c.backend = &ofono.Session{Owner: ":1.42", Modem: "/modem", Epoch: epoch, Queue: ofono.NewSignalQueue()}
	f := &fakeBackend{result: hal.WriteResult{Object: "/modem/call1"}}
	c.executor = f
	c.ready = true
	c.reason = ""
	return c, f, dir
}
func request(c *Coordinator, action string) Request {
	id, _ := identity.UUID()
	return Request{CommandID: id, BootID: c.boot, Epoch: c.epoch(), Deadline: time.Now().Add(30 * time.Second).Format(time.RFC3339Nano), Action: action, Args: Args{Number: "15555550123", Text: "synthetic-test"}}
}
func dispatch(t *testing.T, c *Coordinator, r Request) job {
	t.Helper()
	if got := c.submit(r); got.Code != 202 {
		t.Fatalf("submit %d", got.Code)
	}
	queue := c.callsQueue
	if r.Action == "sms.send" {
		queue = c.smsQueue
	}
	j := <-queue
	b := begin{j, make(chan grant, 1)}
	c.beginJob(b)
	if !(<-b.reply).ok {
		t.Fatal("not dispatched")
	}
	return j
}
func sig(name, path string, seq uint64, body ...any) *dbus.Signal {
	return &dbus.Signal{Sender: ":1.42", Path: dbus.ObjectPath(path), Name: name, Sequence: dbus.Sequence(seq), Body: body}
}
func addCall(c *Coordinator, path, state string, seq uint64) {
	c.signal(sig("org.ofono.VoiceCallManager.CallAdded", "/modem", seq, dbus.ObjectPath(path), map[string]dbus.Variant{"State": dbus.MakeVariant(state)}), 0, 0)
}
func TestWorkerWaitsForCompletionAckAndTwoDialsExecuteOnce(t *testing.T) {
	c, f, _ := newCoordinator(t)
	first, second := request(c, "call.dial"), request(c, "call.dial")
	if c.submit(first).Code != 202 || c.submit(second).Code != 202 {
		t.Fatal("queue")
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go c.worker(c.callsQueue, &wg)
	b := <-c.begin
	c.beginJob(b)
	completed := <-c.results
	select {
	case <-c.begin:
		t.Fatal("next begin preceded completion acknowledgment")
	case <-time.After(20 * time.Millisecond):
	}
	c.complete(completed)
	b = <-c.begin
	c.beginJob(b)
	close(c.callsQueue)
	wg.Wait()
	if f.count.Load() != 1 {
		t.Fatal("duplicate Dial")
	}
	record, _ := c.store.Get(second.CommandID)
	if record.State != "failed" {
		t.Fatal(record.State)
	}
}
func TestDialReplyCannotReviveRemovedOrReusedObject(t *testing.T) {
	for _, reuse := range []bool{false, true} {
		t.Run(map[bool]string{false: "removed", true: "reused"}[reuse], func(t *testing.T) {
			c, _, _ := newCoordinator(t)
			j := dispatch(t, c, request(c, "call.dial"))
			addCall(c, "/modem/call1", "dialing", 1)
			old := c.callObjects["/modem/call1"]
			c.signal(sig("org.ofono.VoiceCallManager.CallRemoved", "/modem", 2, dbus.ObjectPath("/modem/call1")), 0, 0)
			if reuse {
				addCall(c, "/modem/call1", "incoming", 3)
			}
			c.complete(completed{job: j, result: hal.WriteResult{Object: "/modem/call1"}})
			r, _ := c.store.Get(j.request.CommandID)
			if r.State != "outcome_unknown" || c.calls[old].State != "disconnected" {
				t.Fatal("late reply resurrected call")
			}
			if reuse {
				call := c.calls[c.callObjects["/modem/call1"]]
				if call.ID == old || call.Ownership != "incoming" {
					t.Fatal("stole new incoming call")
				}
			} else if len(c.callObjects) != 0 {
				t.Fatal("ghost call")
			}
		})
	}
}
func TestSnapshotSequenceUnknownStateAndWaiting(t *testing.T) {
	c, _, _ := newCoordinator(t)
	c.applySnapshot(hal.ControlSnapshot{Calls: []hal.ControlCall{{Object: "/modem/call1", State: "active"}}})
	id := c.callObjects["/modem/call1"]
	c.signal(sig("org.ofono.VoiceCall.PropertyChanged", "/modem/call1", 5, "State", dbus.MakeVariant("dialing")), 10, 0)
	if c.calls[id].State != "active" {
		t.Fatal("old event overwrote snapshot")
	}
	c.signal(sig("org.ofono.VoiceCall.PropertyChanged", "/modem/call1", 11, "State", dbus.MakeVariant("unexpected")), 10, 0)
	if c.calls[id].State != "unknown" {
		t.Fatal("unknown retained known state")
	}
	r := request(c, "call.hangup")
	r.Args = Args{CallID: id}
	if c.validate(r) != 409 {
		t.Fatal("unmanaged writable")
	}
	c.endCall("/modem/call1")
	addCall(c, "/modem/call1", "waiting", 12)
	r.Action = "call.answer"
	r.Args.CallID = c.callObjects["/modem/call1"]
	if c.validate(r) != 409 {
		t.Fatal("answered waiting call")
	}
}
func TestBindingAndEmergencyChanges(t *testing.T) {
	c, _, _ := newCoordinator(t)
	for _, s := range []*dbus.Signal{sig("org.ofono.Manager.ModemAdded", "/", 1, dbus.ObjectPath("/other"), map[string]dbus.Variant{}), sig("org.ofono.Modem.PropertyChanged", "/modem", 2, "Powered", dbus.MakeVariant(false)), sig("org.ofono.Modem.PropertyChanged", "/modem", 3, "Online", dbus.MakeVariant(false)), sig("org.ofono.Modem.PropertyChanged", "/modem", 4, "Interfaces", dbus.MakeVariant([]string{}))} {
		if c.signal(s, 0, 0) {
			t.Fatal("binding remained valid")
		}
	}
	r := request(c, "call.dial")
	c.signal(sig("org.ofono.VoiceCallManager.PropertyChanged", "/modem", 5, "EmergencyNumbers", dbus.MakeVariant([]string{r.Args.Number})), 0, 0)
	if c.validate(r) != 400 {
		t.Fatal("emergency number allowed")
	}
	old := sig("org.ofono.Manager.ModemRemoved", "/", 6, dbus.ObjectPath("/modem"))
	old.Sender = ":1.2"
	if !c.signal(old, 0, 0) {
		t.Fatal("old owner affected current")
	}
}
func TestSMSPendingAndRemovalNeverProveDeliveryAndBodyNotPersisted(t *testing.T) {
	c, _, dir := newCoordinator(t)
	r := request(c, "sms.send")
	j := dispatch(t, c, r)
	c.complete(completed{job: j, result: hal.WriteResult{Object: "/modem/message1"}})
	c.signal(sig("org.ofono.MessageManager.MessageState", "/modem", 1, dbus.ObjectPath("/modem/message1"), map[string]dbus.Variant{"State": dbus.MakeVariant("sent")}), 0, 0)
	c.signal(sig("org.ofono.MessageManager.MessageRemoved", "/modem", 2, dbus.ObjectPath("/modem/message1")), 0, 0)
	m := c.messages[0]
	if m.State != "sent" || m.Delivery != "unknown" {
		t.Fatal("delivery invented")
	}
	b, e := os.ReadFile(filepath.Join(dir, "commands.json"))
	if e != nil || strings.Contains(string(b), r.Args.Text) || strings.Contains(string(b), r.Args.Number) {
		t.Fatal("payload persisted")
	}
	c.applySnapshot(hal.ControlSnapshot{Messages: []hal.PendingMessage{{Object: "/modem/pending", State: "pending"}}})
	if len(c.messages) != 2 || c.messages[1].Direction != "outgoing" || c.messages[1].State != "queued" {
		t.Fatal("pending mistaken for inbox")
	}
}
func TestDuplicateBeforeBootDeadlineAndRestart(t *testing.T) {
	c, _, dir := newCoordinator(t)
	r := request(c, "sms.send")
	if c.submit(r).Code != 202 {
		t.Fatal("submit")
	}
	again := r
	again.Args.Text = "different"
	if c.submit(again).Code != 409 {
		t.Fatal("digest collision")
	}
	store, e := journal.Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	c.store = store
	c.boot, _ = identity.UUID()
	c.backend.(*ofono.Session).Epoch, _ = identity.UUID()
	if got := c.submit(r); got.Code != 200 {
		t.Fatal("retry checked old boot before digest")
	}
	record, _ := store.Get(r.CommandID)
	if record.State != "expired" {
		t.Fatal("replayed prepared")
	}
}
func TestConcurrentDuplicateAPIOnlyOneQueued(t *testing.T) {
	c, _, _ := newCoordinator(t)
	r := request(c, "sms.send")
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 32; i++ {
			c.handleAPI(<-c.api)
		}
	}()
	var wg sync.WaitGroup
	codes := make(chan int, 32)
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, code := c.Submit(context.Background(), r); codes <- code }()
	}
	wg.Wait()
	<-done
	close(codes)
	created := 0
	for code := range codes {
		if code == 202 {
			created++
		} else if code != 200 {
			t.Fatal(code)
		}
	}
	if created != 1 || len(c.smsQueue) != 1 {
		t.Fatal("duplicate queued")
	}
}
func TestHardwareGateAllowsOnlyManagedCleanup(t *testing.T) {
	c, _, _ := newCoordinator(t)
	call := c.ensureCall("/modem/call1", "active", "", "managed")
	c.hardware = func() bool { return false }
	r := request(c, "call.hangup")
	r.Args = Args{CallID: call.ID}
	if c.validate(r) != 0 {
		t.Fatal("cleanup blocked")
	}
	for _, action := range []string{"call.dial", "call.answer", "call.dtmf", "sms.send"} {
		r.Action = action
		if c.validate(r) != 503 {
			t.Fatal("hardware gate bypassed")
		}
	}
}
func TestInboxBoundsAndOverflowGate(t *testing.T) {
	c, _, _ := newCoordinator(t)
	for i := 0; i < 129; i++ {
		c.incoming("synthetic", "")
	}
	if len(c.messages) != 128 || !c.gap || c.dropped != 1 {
		t.Fatal("inbox unbounded")
	}
	c.incoming(strings.Repeat("x", 8193), "")
	if c.dropped != 2 {
		t.Fatal("oversize text accepted")
	}
	for i := 0; i < 129; i++ {
		c.backend.(*ofono.Session).Queue.DeliverSignal("org.ofono.MessageManager", "IncomingMessage", sig("org.ofono.MessageManager.IncomingMessage", "/modem", uint64(i+1), "x", map[string]dbus.Variant{}))
	}
	c.checkSignals()
	if c.ready {
		t.Fatal("overflow still writable")
	}
}
func TestReceiptExcludesDigestAndPayload(t *testing.T) {
	c, _, _ := newCoordinator(t)
	r := request(c, "sms.send")
	out := c.submit(r)
	b, _ := json.Marshal(out.Value)
	if strings.Contains(string(b), "digest") || strings.Contains(string(b), r.Args.Number) || strings.Contains(string(b), r.Args.Text) {
		t.Fatal("private receipt")
	}
}

func TestSMSFinalEventBeforeReplyRetainsIDAndState(t *testing.T) {
	for _, state := range []string{"sent", "failed"} {
		t.Run(state, func(t *testing.T) {
			c, _, _ := newCoordinator(t)
			j := dispatch(t, c, request(c, "sms.send"))
			c.signal(sig("org.ofono.MessageManager.MessageAdded", "/modem", 1, dbus.ObjectPath("/modem/msg"), map[string]dbus.Variant{"State": dbus.MakeVariant("pending")}), 0, 0)
			id := c.messages[0].ID
			c.signal(sig("org.ofono.MessageManager.MessageState", "/modem", 2, dbus.ObjectPath("/modem/msg"), map[string]dbus.Variant{"State": dbus.MakeVariant(state)}), 0, 0)
			c.signal(sig("org.ofono.MessageManager.MessageRemoved", "/modem", 3, dbus.ObjectPath("/modem/msg")), 0, 0)
			c.complete(completed{job: j, result: hal.WriteResult{Object: "/modem/msg"}})
			r, _ := c.store.Get(j.request.CommandID)
			if r.State != "accepted" || r.MessageID != id || len(c.messages) != 1 || c.messages[0].State != state || c.messages[0].Delivery != "unknown" {
				t.Fatal("late reply lost final event")
			}
		})
	}
}
func TestSMSReusedPathBeforeReplyIsUnknown(t *testing.T) {
	c, _, _ := newCoordinator(t)
	j := dispatch(t, c, request(c, "sms.send"))
	for i := 0; i < 2; i++ {
		c.signal(sig("org.ofono.MessageManager.MessageAdded", "/modem", uint64(i*2+1), dbus.ObjectPath("/modem/msg"), map[string]dbus.Variant{"State": dbus.MakeVariant("pending")}), 0, 0)
		if i == 0 {
			c.signal(sig("org.ofono.MessageManager.MessageRemoved", "/modem", 2, dbus.ObjectPath("/modem/msg")), 0, 0)
		}
	}
	c.complete(completed{job: j, result: hal.WriteResult{Object: "/modem/msg"}})
	r, _ := c.store.Get(j.request.CommandID)
	if r.State != "outcome_unknown" || len(c.messages) != 2 || c.messages[0].ID == c.messages[1].ID {
		t.Fatal("reused message was attributed")
	}
}
func TestLossMarksQueuedFailedAndDispatchedUnknownWithoutReplay(t *testing.T) {
	c, f, _ := newCoordinator(t)
	j := dispatch(t, c, request(c, "sms.send"))
	r := request(c, "call.dial")
	if c.submit(r).Code != 202 {
		t.Fatal("submit")
	}
	oldEpoch := c.epoch()
	c.lose("backend_lost")
	a, _ := c.store.Get(j.request.CommandID)
	b, _ := c.store.Get(r.CommandID)
	if a.State != "outcome_unknown" || b.State != "failed" || !c.gap || c.ready || len(c.pending) != 0 {
		t.Fatal("loss semantics")
	}
	epoch, _ := identity.UUID()
	c.backend = &ofono.Session{Owner: ":1.99", Modem: "/modem", Epoch: epoch, Queue: ofono.NewSignalQueue()}
	c.executor = f
	c.ready = true
	c.applySnapshot(hal.ControlSnapshot{Calls: []hal.ControlCall{{Object: "/modem/call1", State: "active"}}})
	if c.calls[c.callObjects["/modem/call1"]].Ownership != "unmanaged" {
		t.Fatal("recovery took ownership")
	}
	j.request.Epoch = oldEpoch
	reply := make(chan grant, 1)
	c.beginJob(begin{j, reply})
	if (<-reply).ok || f.count.Load() != 0 {
		t.Fatal("replayed lost command")
	}
}
func TestShutdownWithoutBackendIsBounded(t *testing.T) {
	c, _, _ := newCoordinator(t)
	c.backend = nil
	c.executor = nil
	c.ready = false
	ctx, cancel := context.WithCancel(context.Background())
	go c.Run(ctx)
	cancel()
	select {
	case <-c.Done():
	case <-time.After(time.Second):
		t.Fatal("shutdown stuck")
	}
}
func TestUnknownDialBlocksNextAndFailedDialReleasesReservation(t *testing.T) {
	for _, unknown := range []bool{false, true} {
		c, _, _ := newCoordinator(t)
		j := dispatch(t, c, request(c, "call.dial"))
		c.complete(completed{job: j, result: hal.WriteResult{Unknown: unknown, Failed: !unknown}})
		code := c.validate(request(c, "call.dial"))
		if unknown && code != 409 || !unknown && code != 0 {
			t.Fatal("reservation incorrect")
		}
	}
}
func TestAnswerHangupObservedAndMultiCallRejected(t *testing.T) {
	c, _, _ := newCoordinator(t)
	addCall(c, "/modem/call1", "incoming", 1)
	id := c.callObjects["/modem/call1"]
	r := request(c, "call.answer")
	r.Args = Args{CallID: id}
	addCall(c, "/modem/call2", "active", 2)
	if c.validate(r) != 409 {
		t.Fatal("multicall answer")
	}
	c.endCall("/modem/call2")
	j := dispatch(t, c, r)
	c.signal(sig("org.ofono.VoiceCall.PropertyChanged", "/modem/call1", 3, "State", dbus.MakeVariant("active")), 0, 0)
	c.complete(completed{job: j})
	record, _ := c.store.Get(r.CommandID)
	if record.State != "observed" || c.calls[id].Ownership != "managed" {
		t.Fatal("answer observation")
	}
	r = request(c, "call.hangup")
	r.Args = Args{CallID: id}
	j = dispatch(t, c, r)
	c.endCall("/modem/call1")
	c.complete(completed{job: j})
	record, _ = c.store.Get(r.CommandID)
	if record.State != "observed" {
		t.Fatal("hangup observation")
	}
}

func TestExpiredBeforeDispatchAndJournalFailureNeverInvokeBackend(t *testing.T) {
	c, f, _ := newCoordinator(t)
	r := request(c, "sms.send")
	if c.submit(r).Code != 202 {
		t.Fatal("submit")
	}
	j := <-c.smsQueue
	j.deadline = time.Now().Add(-time.Second)
	reply := make(chan grant, 1)
	c.beginJob(begin{j, reply})
	if (<-reply).ok {
		t.Fatal("expired dispatched")
	}
	record, _ := c.store.Get(r.CommandID)
	if record.State != "expired" || f.count.Load() != 0 {
		t.Fatal("expiry")
	}
	c2, f2, dir := newCoordinator(t)
	r = request(c2, "sms.send")
	if c2.submit(r).Code != 202 {
		t.Fatal("submit")
	}
	j = <-c2.smsQueue
	if e := os.Rename(dir, dir+"-moved"); e != nil {
		t.Fatal(e)
	}
	reply = make(chan grant, 1)
	c2.beginJob(begin{j, reply})
	if (<-reply).ok || c2.storeOK || f2.count.Load() != 0 {
		t.Fatal("journal failure dispatched")
	}
}
func TestQueueLimitAndEpochChecks(t *testing.T) {
	c, _, _ := newCoordinator(t)
	for i := 0; i < 8; i++ {
		if c.submit(request(c, "sms.send")).Code != 202 {
			t.Fatal("queue early full")
		}
	}
	if c.submit(request(c, "sms.send")).Code != 429 {
		t.Fatal("queue limit")
	}
	r := request(c, "call.dial")
	r.Epoch, _ = identity.UUID()
	if c.submit(r).Code != 409 {
		t.Fatal("old epoch")
	}
	r = request(c, "call.dial")
	r.BootID, _ = identity.UUID()
	if c.submit(r).Code != 409 {
		t.Fatal("old boot")
	}
}
func TestObservedUnknownSMSStateIsNotReplacedByQueued(t *testing.T) {
	c, _, _ := newCoordinator(t)
	j := dispatch(t, c, request(c, "sms.send"))
	c.signal(sig("org.ofono.MessageManager.MessageAdded", "/modem", 1, dbus.ObjectPath("/modem/msg"), map[string]dbus.Variant{"State": dbus.MakeVariant("unrecognized")}), 0, 0)
	c.complete(completed{job: j, result: hal.WriteResult{Object: "/modem/msg"}})
	if c.messages[0].State != "unknown" {
		t.Fatal("unknown state overwritten")
	}
}

func TestAudioQualificationGenerationRemembersTransientState(t *testing.T) {
	c, _, _ := newCoordinator(t)
	call := c.ensureCall("/modem/call1", "active", "", "managed")
	c.publishAudio()
	initial := c.audioLast
	if !initial.Eligible || initial.CallID != call.ID {
		t.Fatal("active qualification")
	}
	call.State = "held"
	c.publishAudio()
	call.State = "active"
	c.publishAudio()
	if !c.audioLast.Eligible || c.audioLast.Generation <= initial.Generation {
		t.Fatal("transient invalid state forgotten")
	}
	c.ensureCall("/modem/call2", "incoming", "", "incoming")
	c.publishAudio()
	if c.audioLast.Eligible {
		t.Fatal("multicall qualified")
	}
}

func TestCloudMessagesDoNotRebindOldEpoch(t *testing.T) {
	c, _, _ := newCoordinator(t)
	c.messages = []*Message{{ID: "old", epoch: "previous-epoch", Text: "synthetic-old"}, {ID: "current", epoch: c.epoch(), Text: "synthetic-current"}}
	for _, kind := range []string{"messages", "cloud_messages"} {
		reply := make(chan response, 1)
		c.handleAPI(apiRequest{kind: kind, reply: reply})
		result := <-reply
		view := result.Value.(MessagesView)
		if kind == "messages" && len(view.Messages) != 2 {
			t.Fatal("local history changed")
		}
		if kind == "cloud_messages" && (len(view.Messages) != 1 || view.Messages[0].ID != "current" || !view.Gap || view.Epoch != c.epoch()) {
			t.Fatal("old epoch leaked")
		}
	}
}

func (c *Coordinator) signal(s *dbus.Signal, calls, messages uint64) bool {
	return c.event(c.backend.(*ofono.Session).Normalize(s), calls, messages)
}
