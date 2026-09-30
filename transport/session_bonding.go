package transport

import (
	"time"

	"openflux/transport/control"
	"openflux/utils"
)

// Bonding: one Session split over all its live carriers at once, so their
// speeds add up and a carrier that drops leaves the others carrying on.
//
// A client asks for it with SubtypeBonding once the handshake is done; an
// exit that bonds answers the same, and both then split packets (bond
// scheduler), acknowledge what arrived every bondTick (SubtypeBondingAck)
// and put received packets back in order (reorder buffer). Exits that
// predate bonding ignore the offer and the client keeps routing by flow.
// The agreement holds for one peer: a new client, or the exit restarting,
// starts without it until offered and answered again.

const (
	bondTick       = 50 * time.Millisecond
	bondOfferEvery = time.Second
	bondVersion    = 1
)

// bondState is the Session's bonding side; guarded by Session.mu except
// for sched and reorder, which lock themselves.
type bondState struct {
	want      bool     // client: offer bonding; exit: accept it
	agreed    bool     // with peer
	peer      [32]byte // the peer it was agreed with
	lastOffer time.Time
	sched     *bondScheduler
	reorder   *reorderBuffer
	ack       control.BondingAck
	ackDirty  bool
}

// SetBonding makes a client offer bonding to its exit, or an exit refuse
// it (exits accept by default). Call before Start.
func (s *Session) SetBonding(on bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.bond.want = on
}

// Bonding reports whether bonding is on with the current peer.
func (s *Session) Bonding() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.bondingLocked()
}

// BondStats is what bonding has learned of each carrier, nil when off.
func (s *Session) BondStats() map[string]BondLinkStats {
	s.mu.Lock()
	on, sched := s.bondingLocked(), s.bond.sched
	s.mu.Unlock()
	if !on || sched == nil {
		return nil
	}
	return sched.linkStats()
}

func (s *Session) bondingLocked() bool {
	return s.bond.agreed && s.ready && s.bond.peer == s.peer
}

// agreeBondingLocked switches bonding on for the current peer with fresh
// state: sequence numbers restart with every peer.
func (s *Session) agreeBondingLocked() {
	s.bond.agreed = true
	s.bond.peer = s.peer
	s.bond.sched = newBondScheduler()
	s.bond.reorder = newReorderBuffer(s.deliverData)
	s.bond.ack = control.BondingAck{}
	s.bond.ackDirty = false
}

func (s *Session) deliverData(p []byte) {
	s.mu.Lock()
	cb := s.dataCallback
	s.mu.Unlock()
	if cb != nil {
		cb(p)
	}
}

// receiveBondingLocked handles the bonding control messages. It reports
// false for a message this Session does not take (bonding not wanted),
// which then goes on to the control handler as any unknown subtype would.
// Called with s.mu held; returns with it released when it reports true.
func (s *Session) receiveBondingLocked(link *transportLink, sub control.Subtype, payload []byte) bool {
	switch sub {
	case control.SubtypeBonding:
		if !s.bond.want {
			return false
		}
		was := s.bondingLocked()
		if !was {
			s.agreeBondingLocked()
		}
		exit := s.exit
		n := len(s.links)
		s.mu.Unlock()
		if !was {
			utils.Infof("[SESSION] bonding on: packets split over the live carriers (%d configured)", n)
		}
		if exit {
			go func() { _ = s.sendControlVia(link, control.SubtypeBonding, []byte{bondVersion}) }()
		}
		return true
	case control.SubtypeBondingAck:
		on, sched := s.bondingLocked(), s.bond.sched
		s.mu.Unlock()
		if !on {
			return true
		}
		a, err := control.DecodeBondingAck(payload)
		if err != nil {
			utils.Debugf("[SESSION] bonding ack from %q: %v", link.name, err)
			return true
		}
		sched.acked(a, time.Now())
		return true
	}
	return false
}

// bondPick chooses the carrier for data packet seq when bonding is on;
// nil when it is off. Called with s.mu held.
func (s *Session) bondPickLocked(links []*transportLink, seq uint64, size int) *transportLink {
	if !s.bondingLocked() || len(links) == 0 {
		return nil
	}
	names := make([]string, len(links))
	for i, l := range links {
		names[i] = l.name
	}
	now := time.Now()
	name := s.bond.sched.pick(names, size, now)
	s.bond.sched.sent(seq, name, size, now)
	for _, l := range links {
		if l.name == name {
			return l
		}
	}
	return links[0]
}

// bondReceiveLocked takes an accepted data packet when bonding is on and
// returns the reorder buffer to push it to (after s.mu is released); nil
// when bonding is off.
func (s *Session) bondReceiveLocked(seq uint64) *reorderBuffer {
	if !s.bondingLocked() {
		return nil
	}
	s.bond.ack.Set(seq)
	s.bond.ackDirty = true
	return s.bond.reorder
}

// bondLoop offers bonding until answered and, once on, acknowledges data,
// gives up on stale gaps and on packets lost in flight.
func (s *Session) bondLoop() {
	defer s.wg.Done()
	tick := time.NewTicker(bondTick)
	defer tick.Stop()
	for {
		select {
		case <-s.done:
			return
		case <-tick.C:
		}
		now := time.Now()
		s.mu.Lock()
		offer := !s.exit && s.bond.want && s.ready && !s.bondingLocked() && now.Sub(s.bond.lastOffer) >= bondOfferEvery
		if offer {
			s.bond.lastOffer = now
		}
		on := s.bondingLocked()
		var ack []byte
		if on && s.bond.ackDirty {
			ack = s.bond.ack.Encode()
			s.bond.ackDirty = false
		}
		sched, reorder := s.bond.sched, s.bond.reorder
		s.mu.Unlock()

		if offer {
			if err := s.SendControl(control.SubtypeBonding, []byte{bondVersion}); err != nil {
				utils.Debugf("[SESSION] bonding offer: %v", err)
			}
		}
		if !on {
			continue
		}
		reorder.tick(now)
		sched.expire(now)
		if ack != nil {
			if err := s.SendControl(control.SubtypeBondingAck, ack); err != nil {
				utils.Debugf("[SESSION] bonding ack: %v", err)
			}
		}
	}
}
