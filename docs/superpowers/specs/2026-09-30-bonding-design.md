# Bonding: one Session over several networks at once

Status: approved 2026-09-30 (variant A). Scope: core, Android, Desktop. iOS later.

## Goal

A client with two networks (a phone's mobile data and Wi-Fi from another
operator's modem; a PC's Ethernet and Wi-Fi) sends one Session over both at
once: their speeds add up, and when one network drops the traffic moves to
the other in under a second. It works over any carriers, including the
documents that pass whitelist-only networks.

Success: one TCP flow over two Mail.ru documents on two networks gets at
least 1.5x the throughput of one document; cutting one network stalls the
flow for less than a second.

## What exists

- Session keeps several carriers (links) with priorities; every IPv4 packet
  carries `DataTail.Sequence`; a 4096-packet replay window accepts packets
  out of order and drops duplicates.
- `Session.Send` spreads *flows* (hash of the 5-tuple) over the live links
  of the top priority. One flow always rides one link.
- Every carrier dials through `netbind`, which binds all sockets to one
  interface on Windows (full tunnel) and does nothing elsewhere.

## Design

### 1. Agreement (backward compatible)

A new hello capability bit would break old exits (`validParameters` rejects
unknown bits, so the handshake fails). Instead, after the handshake a client
with bonding on sends a control message `SubtypeBonding` (payload: version
byte 1). An exit that supports bonding answers `SubtypeBonding` too and
switches bonding on for this peer; an old exit ignores the unknown subtype.
The client repeats the offer on each keepalive until answered, and stripes
only once answered. A new session (peer restart, takeover) starts with
bonding off until agreed again.

### 2. Sending: acknowledged in-flight per link

Carriers queue internally (a document's write queue), so the sender cannot
see a link's real speed from its own queue. The receiver reports what
arrived instead, as SRTLA does with SRT ACKs:

- With bonding agreed, the receiver sends `SubtypeBondingAck` every 50 ms
  while data arrives: the newest sequence it accepted and a 512-bit map of
  the 512 numbers up to it (72 bytes). A lost ack is covered by the next.
- The sender remembers, for each packet in flight, the link, size and send
  time. An ack credits the packet's link: in-flight bytes go down,
  delivered bytes and an RTT sample go up. A packet unacknowledged for
  2 s counts as lost and leaves the in-flight count.
- `rate` per link is an EWMA of delivered bytes per second over 250 ms
  windows; it starts at 256 KiB/s and never goes under 16 KiB/s.
- Every live link (heard lately; see `liveLinksLocked`) is a candidate
  regardless of priority; each packet goes to the one with the smallest
  `(inflight + len(p)) / rate`.
- Control messages and hellos go as today.

Both sides stripe once agreed (the exit's replies too). Attribution needs
no link names: the sender knows which link carried which number, so a
document joined twice from one client works as well.

### 3. Receiving: reorder buffer

With bonding agreed, `receiveIPv4` hands accepted packets to a reorder
buffer instead of the callback. It delivers packets in sequence order; on
a gap it waits for the missing number up to `hold`, then skips it (TCP
inside retransmits). `hold` adapts: the EWMA of how late gap-filling packets
arrived, times 1.5, clamped to [20 ms, 500 ms], starting at 100 ms. The
buffer holds at most 4096 packets (the replay window); overflow flushes in
order. Without bonding the buffer is not used and nothing changes.

### 4. Binding a carrier to a network

- `TransportConfig.Network`: `""` (default route), `cellular`, `wifi`,
  `ethernet`. In a `.conf`: `Network = cellular` in a `[Transport]`
  section; in Session specs JSON: `"network"`.
- `netbind.DialContextFor(network)` / `WrapFor(network, *net.Dialer)`
  apply the global binding and then the per-network one. Every carrier
  dials through them with its config's network.
- `netbind.SetNetworkBinder(func(network string, fd uintptr) error)`:
  platforms register how to bind a socket. Android: the mobile library's
  `NetworkBinder` interface, implemented in Kotlin with
  `Network.bindSocket`. Windows: the interface index of the first adapter
  that is up and of that type (Wi-Fi 71, Ethernet 6, WWAN 243/244), via
  `IP_UNICAST_IF`.
- A network that is not available fails the dial; the carrier retries as
  today and stays out of the bonding while down.

### 5. Android

- Profile: `bonding: Boolean`; each carrier: `network` (any, mobile,
  Wi-Fi). Kept on the device, not in `openflux://` links.
- The service requests the networks the profile names
  (`ConnectivityManager.requestNetwork`, `CHANGE_NETWORK_STATE`), so mobile
  data stays up next to Wi-Fi, and binds sockets with `Network.bindSocket`.
- Profile editor: a «Бондинг» switch and a network choice per carrier. Home:
  the bonded links with their network and speed.

### 6. Desktop

Same profile fields (network choice adds Ethernet); the `.conf` gets
`Network =`; the core binds by adapter type. Home shows the bonded links.

## Testing

- Unit (transport): links with set rate/latency/drop; the scheduler's split
  follows the acknowledged rates; acks encode and decode; the reorder buffer restores order and skips a lost
  number after `hold`; a link dying mid-flow stalls less than `hold` plus
  one keepalive; a bonding client with an old exit never stripes; the exit
  reorders only after agreement.
- Unit (netbind): `DialContextFor` calls the binder with the network.
- Live: two local peers over two Mail.ru documents, one TCP flow, against
  one document.

## Out of scope

iOS; duplicating packets over several links; bonding classic peers.
