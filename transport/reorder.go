package transport

import (
	"sync"
	"time"
)

// Reorder buffer limits (see reorderBuffer).
const (
	reorderHoldStart = 100 * time.Millisecond
	reorderHoldMin   = 20 * time.Millisecond
	reorderHoldMax   = 500 * time.Millisecond
	// reorderCapacity matches the replay window: nothing older can arrive.
	reorderCapacity = replayWindowSize
)

// reorderBuffer puts a bonded Session's packets back in sequence order. The
// carriers of a bonding differ in latency by tens to hundreds of
// milliseconds, so packets of one flow overtake each other; handed to the
// tunnel as they come, TCP would take every overtaken segment for a loss
// and halve its window. The buffer holds packets behind a gap for up to
// hold, then gives up on the missing one (a carrier that died with it in
// flight) and moves on: TCP inside retransmits it. hold follows how late
// gap-filling packets actually arrive, so it stays near the latency
// difference of the carriers in use.
type reorderBuffer struct {
	mu       sync.Mutex
	deliver  func([]byte)
	started  bool
	next     uint64
	pending  map[uint64]heldPacket
	lateness time.Duration // EWMA of how late gap-filling packets came
	hold     time.Duration
}

type heldPacket struct {
	p  []byte
	at time.Time // arrival
}

func newReorderBuffer(deliver func([]byte)) *reorderBuffer {
	return &reorderBuffer{
		deliver:  deliver,
		pending:  make(map[uint64]heldPacket),
		hold:     reorderHoldStart,
		lateness: reorderHoldStart * 2 / 3,
	}
}

// push takes packet seq and delivers everything that is now in order.
// Sequence numbers come from the replay window, so each arrives once.
func (r *reorderBuffer) push(seq uint64, p []byte, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.started {
		r.started = true
		r.next = seq
	}
	switch {
	case seq < r.next:
		// Came after its gap was given up on: late is better than lost.
		r.deliver(p)
		return
	case seq > r.next:
		r.pending[seq] = heldPacket{p, now}
		if len(r.pending) > reorderCapacity {
			oldest, _ := r.oldestLocked()
			r.next = oldest
			r.drainLocked()
		}
		return
	}
	if oldest, ok := r.oldestLocked(); ok {
		r.learnLocked(now.Sub(r.pending[oldest].at))
	}
	r.deliver(p)
	r.next++
	r.drainLocked()
}

// tick gives up on every gap that packets after it have waited out hold
// behind. A carrier that died with packets in flight leaves gaps all
// through the stream: they go together, not one hold each.
func (r *reorderBuffer) tick(now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for {
		oldest, ok := r.oldestLocked()
		if !ok || now.Sub(r.pending[oldest].at) < r.hold {
			return
		}
		r.next = oldest
		r.drainLocked()
	}
}

func (r *reorderBuffer) holdTime() time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.hold
}

// reset forgets everything: a new peer numbers its packets afresh.
func (r *reorderBuffer) reset() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.started = false
	r.pending = make(map[uint64]heldPacket)
}

// oldestLocked is the lowest sequence held behind a gap.
func (r *reorderBuffer) oldestLocked() (uint64, bool) {
	oldest, ok := uint64(0), false
	for seq := range r.pending {
		if !ok || seq < oldest {
			oldest, ok = seq, true
		}
	}
	return oldest, ok
}

// drainLocked delivers the in-order run at next.
func (r *reorderBuffer) drainLocked() {
	for {
		h, ok := r.pending[r.next]
		if !ok {
			return
		}
		delete(r.pending, r.next)
		r.deliver(h.p)
		r.next++
	}
}

func (r *reorderBuffer) learnLocked(late time.Duration) {
	r.lateness += (late - r.lateness) / 8
	h := r.lateness * 3 / 2
	r.hold = min(max(h, reorderHoldMin), reorderHoldMax)
}
