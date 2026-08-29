# Bug - the wire client asserts on the peer's read cursor: a non-advancing `next` panics or loops forever

## TL;DR

- **What failed:** `net.client.Client.read` paged through a journal and drove its cursor from the `read_page.next` the peer sent, guarded by `std.debug.assert(order(page.next, position) == .gt)`.
- **Impact:** A peer that answers with a cursor at or behind the one it was asked for panics the CLI in a safe build, and spins issuing the same `read_req` forever in a release build. The peer's reply is untrusted input; every other decode path in `src/net/` refuses it by name instead.
- **Resolution:** Fixed. The cursor is checked and refused with `error.ProtocolError`.

## Status

Resolved.

## Symptom and impact

`src/net/client.zig`, before the fix:

```zig
if (page.next.epoch == 0 and page.next.seq == 0) return; // done
std.debug.assert(slot.Position.order(page.next, position) == .gt);
position = page.next;
```

`coppiz read` against a serving node runs this loop. `(0, 0)` is the
end-of-stream marker, so any other non-advancing value falls through to the
assert. In `ReleaseFast` and `ReleaseSmall` the assert is compiled out and the
loop re-sends the same request at the same position without bound.

This is hardening, not a live failure: the shipped `onReadReq` only ever sets a
`next` strictly past the last record it encoded, so a coppiz node does not
produce the bad cursor. A different implementation of the wire, a corrupted
middlebox, or a future change to the paging rule does.

## Reproduction

New test `a read page whose cursor does not advance is refused, not looped` in
`src/net/client.zig`: a hub-backed server answers the hello, then answers both
`read_req`s with `next = (1, 1)`. The second answer does not advance past the
cursor the client already holds.

- Expected: `client.read` returns an error.
- Actual, before the fix: the safe-build assert fires and the test binary panics.

## Root cause

The paging loop treated a wire field as an internal invariant. `assert` states
what this code guarantees; the cursor is what the other end guarantees, and
`src/net/`'s stated rule is that a decoder never trusts its input.

## Resolution

The assert became a check that returns `error.ProtocolError`, which the CLI
already reports like any other wire failure. Nothing else in the loop changed:
`(0, 0)` still means the stream is done.

## Verification

- New test above: it panics on the pre-fix code and passes after.
- `zig build test`.

## Follow-up

None. The rest of `Client` already returns `error.ProtocolError` for an
unexpected reply kind, so the failure has one name.

## References

- Code: `src/net/client.zig` (`Client.read`), `src/cluster/node.zig` (`onReadReq`, the cursor's producer)
- Fix: this change
