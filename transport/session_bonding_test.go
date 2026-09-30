package transport

import (
	"crypto/rand"
	"encoding/binary"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"openflux/transport/control"
)

// delayWire is one end of an in-memory carrier with a one-way delay: what
// is sent arrives, in order, delay later. Frames over 900 bytes (data
// packets in these tests) are counted, and down drops everything sent.
type delayWire struct {
	mu    sync.Mutex
	cb    func([]byte)
	out   chan wireFrame
	delay time.Duration
	down  atomic.Bool
	data  atomic.Int64
}

type wireFrame struct {
	p  []byte
	at time.Time
}

func delayPair(delay time.Duration) (*delayWire, *delayWire) {
	a := &delayWire{out: make(chan wireFrame, 8192), delay: delay}
	b := &delayWire{out: make(chan wireFrame, 8192), delay: delay}
	pump := func(from, to *delayWire) {
		for d := range from.out {
			time.Sleep(time.Until(d.at.Add(from.delay)))
			to.mu.Lock()
			cb := to.cb
			to.mu.Unlock()
			if cb != nil {
				cb(d.p)
			}
		}
	}
	go pump(a, b)
	go pump(b, a)
	return a, b
}

func (w *delayWire) Start() error          { return nil }
func (w *delayWire) Stop() error           { return nil }
func (w *delayWire) IsConnected() bool     { return true }
func (w *delayWire) Stats() TransportStats { return TransportStats{} }
func (w *delayWire) Receive(cb func([]byte)) {
	w.mu.Lock()
	w.cb = cb
	w.mu.Unlock()
}
func (w *delayWire) Send(p []byte) error {
	if w.down.Load() {
		return nil
	}
	if len(p) > 900 {
		w.data.Add(1)
	}
	w.out <- wireFrame{append([]byte(nil), p...), time.Now()}
	return nil
}

// bondPeers starts a client and an exit joined by two carriers of equal
// priority, "a" (fast) and "b" (slow).
func bondPeers(t *testing.T, clientBonds, exitBonds bool) (cl, ex *Session, a, b [2]*delayWire) {
	t.Helper()
	params := PeerParameters{Capabilities: control.CapabilityIPv4 | control.CapabilityTCP | control.CapabilityUDP, MaxPacketSize: MaxNegotiatedPacket}
	var err error
	if cl, err = NewSession(params, false); err != nil {
		t.Fatal(err)
	}
	if ex, err = NewSession(params, true); err != nil {
		t.Fatal(err)
	}
	cl.SetBonding(clientBonds)
	ex.SetBonding(exitBonds)
	a[0], a[1] = delayPair(10 * time.Millisecond)
	b[0], b[1] = delayPair(40 * time.Millisecond)
	for _, x := range []struct {
		s    *Session
		a, b *delayWire
	}{{cl, a[0], b[0]}, {ex, a[1], b[1]}} {
		if err := x.s.AddTransport("a", x.a, compatSecret, "ctx", 100); err != nil {
			t.Fatal(err)
		}
		if err := x.s.AddTransport("b", x.b, compatSecret, "ctx", 100); err != nil {
			t.Fatal(err)
		}
	}
	if err := ex.Start(); err != nil {
		t.Fatal(err)
	}
	if err := cl.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cl.Stop(); ex.Stop() })
	return
}

func waitBonding(t *testing.T, s ...*Session) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for _, x := range s {
		for !x.Bonding() {
			if time.Now().After(deadline) {
				t.Fatal("bonding not agreed")
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
}

// numbered is a 1000-byte TCP packet of one flow carrying n.
func numbered(n uint32) []byte {
	p := testIPv4(1000, 6)
	rand.Read(p[44:]) // incompressible, so the carriers' frames show the split
	binary.BigEndian.PutUint32(p[40:], n)
	return p
}

// sendNumbered sends count numbered packets, calling at(i) before each, and
// collects what the other side delivers until count arrived or wait passed.
func sendNumbered(t *testing.T, from, to *Session, count int, wait time.Duration, at func(i int)) ([]uint32, time.Time) {
	t.Helper()
	var mu sync.Mutex
	var got []uint32
	var last time.Time
	done := make(chan struct{})
	to.Receive(func(p []byte) {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, binary.BigEndian.Uint32(p[40:]))
		last = time.Now()
		if len(got) == count {
			close(done)
		}
	})
	for i := 1; i <= count; i++ {
		if at != nil {
			at(i)
		}
		if err := from.Send(numbered(uint32(i))); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
		if i%4 == 0 {
			time.Sleep(time.Millisecond)
		}
	}
	select {
	case <-done:
	case <-time.After(wait):
	}
	mu.Lock()
	defer mu.Unlock()
	return append([]uint32(nil), got...), last
}

func TestBondingSplitsAndKeepsOrder(t *testing.T) {
	cl, ex, a, b := bondPeers(t, true, true)
	waitBonding(t, cl, ex)
	got, _ := sendNumbered(t, cl, ex, 2000, 10*time.Second, nil)
	if len(got) != 2000 {
		t.Fatalf("%d of 2000 arrived", len(got))
	}
	for i, n := range got {
		if n != uint32(i+1) {
			t.Fatalf("out of order at %d: %d", i, n)
		}
	}
	// Frames, not packets: the carriers batch several packets per frame.
	na, nb := a[0].data.Load(), b[0].data.Load()
	if min(na, nb)*100 < (na+nb)*15 {
		t.Fatalf("split a=%d b=%d frames: one carrier did nearly all the work", na, nb)
	}
	if st := cl.BondStats(); len(st) != 2 {
		t.Fatalf("bond stats %v", st)
	}
}

func TestBondingNotWithAnOldExit(t *testing.T) {
	cl, ex, a, b := bondPeers(t, true, false)
	got, _ := sendNumbered(t, cl, ex, 500, 10*time.Second, nil)
	if len(got) != 500 {
		t.Fatalf("%d of 500 arrived", len(got))
	}
	if cl.Bonding() || ex.Bonding() {
		t.Fatal("bonding on with an exit that does not bond")
	}
	// Routing by flow: the flow stays on one carrier, but for the first
	// frames, sent while the other one had not been heard from yet.
	na, nb := a[0].data.Load(), b[0].data.Load()
	if min(na, nb)*100 > (na+nb)*20 {
		t.Fatalf("one flow split over both carriers (a=%d b=%d) without bonding", na, nb)
	}
}

func TestBondingSurvivesACarrierDying(t *testing.T) {
	cl, ex, _, b := bondPeers(t, true, true)
	waitBonding(t, cl, ex)
	var sentAll time.Time
	got, last := sendNumbered(t, cl, ex, 2000, 6*time.Second, func(i int) {
		if i == 800 {
			b[0].down.Store(true)
			b[1].down.Store(true)
		}
		if i == 2000 {
			sentAll = time.Now()
		}
	})
	t.Logf("%d of 2000 arrived, the tail %v after the last send", len(got), last.Sub(sentAll))
	if len(got) < 1700 {
		t.Fatalf("only %d of 2000 arrived after a carrier died", len(got))
	}
	if got[len(got)-1] != 2000 {
		t.Fatalf("the last packet did not arrive (last %d)", got[len(got)-1])
	}
	for i := 1; i < len(got); i++ {
		if got[i] < got[i-1] && got[i-1]-got[i] > 50 {
			t.Fatalf("far out of order at %d: %d after %d", i, got[i], got[i-1])
		}
	}
	if d := last.Sub(sentAll); d > reorderHoldMax+time.Second {
		t.Fatalf("the tail came %v after the last send: delivery stalled", d)
	}
}
