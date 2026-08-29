# Bug - `readerMain` reads the `conns` map from a pool thread while the loop thread mutates it (latent, not fixed)

## TL;DR

- **What failed:** `ClusterNode.readerMain` opens with
  `const conn = self.conns.get(conn_id).?.conn;`. It runs as its own
  `std.Io.Group` task, so that read is on a pool thread, while every
  `put` and `remove` on the same map runs on the loop thread. Nothing
  synchronises the two.
- **Impact:** An unsynchronised read of a container another thread is
  writing. When the write is a `put` that grows the table, the table is
  reallocated and the old allocation freed, so the reader can be walking
  freed memory: `.?` on a miss is `unreachable`, and a torn read yields a
  `Conn` whose function pointers are garbage.
- **Resolution:** **Not fixed.** `src/cluster/node.zig` is outside the
  territory of the sweep that found this. Suggested fix below; it is one
  line.

## Status

Open. Found by reading, not by an observed failure - see *Reproduction*.

## Symptom and impact

`src/cluster/node.zig`:

```zig
fn readerMain(self: *ClusterNode, conn_id: u64) error{Canceled}!void {
    const conn = self.conns.get(conn_id).?.conn;
    while (true) {
        const body = conn.recv(self.io, self.allocator) catch break;
        ...
```

and its spawn, on the loop thread:

```zig
fn onConnReady(self: *ClusterNode, conn: net.transport.Conn, outbound: bool) !void {
    const conn_id = self.next_conn_id;
    self.next_conn_id += 1;
    errdefer conn.close(self.io);
    try self.conns.put(self.allocator, conn_id, .{ .conn = conn, .outbound = outbound });
    self.group.async(self.io, readerMain, .{ self, conn_id });
}
```

`self.conns` is a `std.AutoHashMapUnmanaged(u64, ConnState)`. Every one of
its other seventeen accesses is on the loop thread: `onConnReady` puts,
`onPeerGone` gets and removes, `onFrame` and the send helpers get, and
`deinit` iterates. Line 780 is the only one that is not, and it is a read
with no lock, no atomic and no handshake.

The task is spawned but not awaited at the spawn point, so the loop returns
to `mailbox.wait` and can process the next `conn_ready` - another `put` -
before the reader has run its first line. A member mesh forms exactly that
way: every peer dials at once, and CLI clients add more conns on the same
map.

## Reproduction

Not reproduced. This is a code-read finding, and it is recorded as one: no
test in the tree fails because of it, and provoking it would need a
scheduling window this suite has no way to force. Do not read the sections
below as a repro.

What *is* demonstrated is the mechanism that turns the race into a
use-after-free rather than a stale read. A standalone test over the same
map type, with the same value type, printing the table's address after each
insert:

```
put #7:  table moved 0x104480018 -> 0x1044a0018
put #13: table moved 0x1044a0018 -> 0x1044c0018
put #26: table moved 0x1044c0018 -> 0x1044a0018
put #52: table moved 0x1044a0018 -> 0x1044c0018
total moves while inserting 63 entries: 4
```

Each move is an allocation of a new table and a free of the old one. A
`get` in flight across one of those holds the old pointer.

Note also that the race does not need a move to be a defect: a read
concurrent with a write, with no synchronisation, has no defined result in
Zig regardless of whether the backing memory happens to stay put. The move
is what decides how bad the undefined result is.

## Root cause

`readerMain` needs one thing from the map - the `Conn` value - and takes
the id instead, so it has to look the value up on a thread that has no
claim on the map. The value was in hand at the spawn site.

`Conn` is a small value type (four function pointers and a context
pointer), and its lifetime already covers the reader's: `onPeerGone` is
the only path that closes it, and it runs after the reader has exited and
posted `peer_gone`. So there is nothing about the id-then-lookup shape that
the value could not have done directly.

## Suggested fix (not applied)

Pass the value the task needs, so the pool thread never touches the map:

```zig
    self.group.async(self.io, readerMain, .{ self, conn_id, conn });
```

```zig
fn readerMain(self: *ClusterNode, conn_id: u64, conn: net.transport.Conn) error{Canceled}!void {
    while (true) {
```

`conn_id` is still needed for the `frame` and `peer_gone` events. The
`.?` disappears with the lookup, which also removes an `unreachable` on a
path a shutdown race could otherwise reach.

Whoever applies it owns checking one thing this report did not: that no
other `self.conns` access has drifted onto a non-loop thread since.

## Follow-up

The same question is worth asking of the other `ClusterNode` fields a task
touches. `dialMain`, `acceptMain` and `timerMain` were read while writing
this and only use `self.io`, `self.allocator`, `self.options`,
`self.mailbox` and `self.tick_ms` (an atomic) - none of which is a
container the loop resizes. `readerMain` is the only task that reaches into
one.

## References

- Code: `src/cluster/node.zig` (`readerMain`, `onConnReady`, `onPeerGone`,
  `deinit`)
- Related: [2026-08-29-hub-pipes-append-unsynchronised.md](2026-08-29-hub-pipes-append-unsynchronised.md)
  and [2026-08-28-hub-listener-close-race.md](2026-08-28-hub-listener-close-race.md)
  are the same class on the hub side, both fixed with a mutex.
- Fix: none
