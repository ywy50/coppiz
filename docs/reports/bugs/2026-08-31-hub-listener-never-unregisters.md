# Bug - closing a hub listener leaves its address taken for the life of the hub

## TL;DR

- **What failed:** `HubListener.closeFn` marked the endpoint closed but
  never removed it from `Hub.endpoints`, and `Hub.listen` refuses an address
  the map still holds.
- **Impact:** an address can be listened on exactly once per hub. A node
  that stops and restarts in the in-memory fabric cannot re-listen on the
  address it had, so no scenario can restart a member - including the
  `sim.LoopWorld` scenarios the fabric exists for.
- **Resolution:** fixed - the endpoint leaves the map on close and is
  retired to a list the hub frees at `deinit`.

## Status

Resolved 2026-08-31. Found by reading; no scenario had tried to restart a
member, which is why nothing had hit it.

## Symptom and impact

`Hub` is the in-memory transport the cluster loop runs over in tests and in
the simulator, standing in for TCP ([PRD 0003](../../prds/0003-membership-and-leadership.md)
phase 4). `listen` registers an address:

```
if (self.endpoints.contains(address)) return error.AddressInUse;
```

and the close path did not undo it:

```
self.endpoint.closed = true;
self.endpoint.sem.post(io);
self.hub.allocator.free(self.address);
self.hub.allocator.destroy(self);
```

`closed = true` is enough for the *connection* semantics - `acceptConn`
refuses, `pushConn` closes anything that arrives - so a closed listener
behaves correctly toward peers. What it does not do is give the address
back. Every later `listen` on it answers `AddressInUse`, for as long as the
hub lives.

This is not a leak: `Hub.deinit` walks `endpoints` and frees each one, so
the memory is accounted for. It is a lifecycle limit, and it lands exactly
on the scenario the fabric was built to run - stop a member, start it again
at the same address, watch it rejoin.

## Reproduction

`src/net/transport.zig`, test *closing a hub listener frees its address for
a new one*: listen on `node-a`, confirm a second `listen` is refused, close
the first, then listen on `node-a` again and use it.

Expected: the second listener takes the address and echoes over it. Before
the fix the second `listen` returns `error.AddressInUse`.

## Root cause

Two pieces of state describe one listener - the endpoint's `closed` flag and
the map entry that reserves its address - and only the first was maintained
on the close path.

Destroying the endpoint there is not safe, which is likely why the entry was
left alone: `HubDialer.connectFn` deliberately releases the hub lock before
calling `ep.pushConn` (the lock is never held across an `Endpoint` call, so
that two dials cannot deadlock against an accept), so a dial that looked the
endpoint up a moment before the close may still be inside it.

## Resolution

`closeFn` takes the hub lock, moves the endpoint from `endpoints` to a new
`retired` list, and frees the map key; the endpoint itself is freed by
`Hub.deinit`, which outlives every dial. The endpoint mutex is taken after
the hub lock is released, so the "never held across an `Endpoint` call"
discipline is unchanged.

The retirement slot is reserved before the entry is removed. If that
allocation fails the endpoint stays in the map, owned by it - the address
stays taken, which is the old behaviour, rather than an endpoint owned by
nothing.

## Verification

- The test fails before the fix with `error.AddressInUse` from the second
  `listen` and passes after it.
- The existing `hubRound` allocation-failure sweep covers the new path: it
  drives listen/dial/teardown under an allocator that fails at each
  allocation index in turn, backed by a GPA that panics on a leak or a
  double free.
- `zig build test` green on the branch.

## Follow-up

None. `TcpListener` has no equivalent problem: the operating system frees
the port when the socket closes.
