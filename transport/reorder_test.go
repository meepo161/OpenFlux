package transport

import (
	"reflect"
	"testing"
	"time"
)

func newTestReorder() (*reorderBuffer, *[]uint64) {
	var got []uint64
	r := newReorderBuffer(func(p []byte) { got = append(got, uint64(p[0])) })
	return r, &got
}

func pkt(seq uint64) []byte { return []byte{byte(seq)} }

func TestReorderInOrderPassesStraight(t *testing.T) {
	r, got := newTestReorder()
	t0 := time.Unix(0, 0)
	for s := uint64(1); s <= 5; s++ {
		r.push(s, pkt(s), t0)
	}
	if !reflect.DeepEqual(*got, []uint64{1, 2, 3, 4, 5}) {
		t.Fatalf("got %v", *got)
	}
}

func TestReorderRestoresOrder(t *testing.T) {
	r, got := newTestReorder()
	t0 := time.Unix(0, 0)
	r.push(1, pkt(1), t0)
	r.push(3, pkt(3), t0)
	r.push(4, pkt(4), t0)
	if !reflect.DeepEqual(*got, []uint64{1}) {
		t.Fatalf("delivered past a gap: %v", *got)
	}
	r.push(2, pkt(2), t0.Add(30*time.Millisecond))
	if !reflect.DeepEqual(*got, []uint64{1, 2, 3, 4}) {
		t.Fatalf("got %v", *got)
	}
}

func TestReorderSkipsAGapAfterHold(t *testing.T) {
	r, got := newTestReorder()
	t0 := time.Unix(0, 0)
	r.push(1, pkt(1), t0)
	r.push(3, pkt(3), t0)
	r.tick(t0.Add(r.holdTime() / 2))
	if len(*got) != 1 {
		t.Fatalf("skipped before hold: %v", *got)
	}
	r.tick(t0.Add(r.holdTime() + time.Millisecond))
	if !reflect.DeepEqual(*got, []uint64{1, 3}) {
		t.Fatalf("gap not skipped: %v", *got)
	}
	// The late packet still reaches the tunnel: TCP takes it as a duplicate
	// or a hole filled, both better than losing it.
	r.push(2, pkt(2), t0.Add(time.Second))
	if !reflect.DeepEqual(*got, []uint64{1, 3, 2}) {
		t.Fatalf("late packet lost: %v", *got)
	}
}

func TestReorderHoldAdapts(t *testing.T) {
	r, _ := newTestReorder()
	t0 := time.Unix(0, 0)
	seq := uint64(1)
	r.push(seq, pkt(seq), t0)
	// Gaps that fill 300 ms late, again and again: hold grows towards 450 ms.
	for i := 0; i < 40; i++ {
		now := t0.Add(time.Duration(i) * time.Second)
		r.push(seq+2, pkt(seq+2), now)
		r.push(seq+1, pkt(seq+1), now.Add(300*time.Millisecond))
		seq += 2
	}
	if h := r.holdTime(); h < 400*time.Millisecond || h > reorderHoldMax {
		t.Fatalf("hold %v after 300 ms fills", h)
	}
	// Gaps that fill at once: hold shrinks to the floor.
	for i := 0; i < 80; i++ {
		now := t0.Add(time.Duration(100+i) * time.Second)
		r.push(seq+2, pkt(seq+2), now)
		r.push(seq+1, pkt(seq+1), now)
		seq += 2
	}
	if h := r.holdTime(); h != reorderHoldMin {
		t.Fatalf("hold %v after instant fills", h)
	}
}

func TestReorderOverflowFlushes(t *testing.T) {
	r, got := newTestReorder()
	t0 := time.Unix(0, 0)
	r.push(1, pkt(1), t0)
	for s := uint64(3); s < 3+reorderCapacity+1; s++ {
		r.push(s, []byte{0}, t0)
	}
	if len(*got) < 2 {
		t.Fatalf("buffer grew past its capacity without flushing (%d delivered)", len(*got))
	}
}
