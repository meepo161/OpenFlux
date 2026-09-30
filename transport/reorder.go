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
	pending  map[uint64][]byte
	gapSince time.Time
	lateness time.Duration // EWMA of how late gap-filling packets came
	hold     time.Duration
}

func newReorderBuffer(deliver func([]byte)) *reorderBuffer {
	return &reorderBuffer{
		deliver:  deliver,
		pending:  make(map[uint64][]byte),
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
		if len(r.pending) == 0 {
			r.gapSince = now
		}
		r.pending[seq] = p
		if len(r.pending) > reorderCapacity {
			r.skipLocked(now)
		}
		return
	}
	if len(r.pending) > 0 {
		r.learnLocked(now.Sub(r.gapSince))
	}
	r.deliver(p)
	r.next++
	r.drainLocked(now)
}

// tick gives up on a gap older than hold.
func (r *reorderBuffer) tick(now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.pending) > 0 && now.Sub(r.gapSince) >= r.hold {
		r.skipLocked(now)
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
	r.pending = make(map[uint64][]byte)
}

// skipLocked moves past the gap to the oldest pending packet.
func (r *reorderBuffer) skipLocked(now time.Time) {
	oldest := uint64(0)
	for seq := range r.pending {
		if oldest == 0 || seq < oldest {
			oldest = seq
		}
	}
	r.next = oldest
	r.drainLocked(now)
}

// drainLocked delivers the in-order run at next; a gap left behind starts
// its own clock.
func (r *reorderBuffer) drainLocked(now time.Time) {
	for {
		p, ok := r.pending[r.next]
		if !ok {
			break
		}
		delete(r.pending, r.next)
		r.deliver(p)
		r.next++
	}
	if len(r.pending) > 0 {
		r.gapSince = now
	}
}

func (r *reorderBuffer) learnLocked(late time.Duration) {
	r.lateness += (late - r.lateness) / 8
	h := r.lateness * 3 / 2
	r.hold = min(max(h, reorderHoldMin), reorderHoldMax)
}
