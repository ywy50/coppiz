# Bug - `Hub.drop` leaks the edge key every time an already-dropped edge is dropped again

## TL;DR

- **What failed:** `Hub.drop` allocated a fresh `"from\x00to"` key and handed it to `dropped.put`. A hash map's `put` keeps the key it already holds, so on a repeat drop of the same edge the fresh allocation was owned by nobody and never freed.
- **Impact:** A leak in the in-memory hub transport, which is what the in-process cluster tests and `examples/embed-cluster` run on. A scenario that drops one direction more than once (an asymmetric partition widened in two steps, or a partition re-applied after a crash) leaks one key per repeat.
- **Resolution:** Fixed. `drop` probes with a borrowed key and only allocates an owned one when the edge is not already dropped.

## Status

Resolved.

## Symptom and impact

`src/net/transport.zig`, before the fix:

```zig
const key = try edgeKey(allocator, from, to);
// The map owns the key (freed at deinit); it is never freed here.
try self.dropped.put(allocator, key, {});
```

The comment states the invariant the code does not keep. `std.HashMapUnmanaged.put`
resolves to `getOrPut`; on `found_existing` it assigns the value and leaves the
stored key in place. The caller's key is then unreachable.

The same call site also mixed allocators: the key was allocated from the
caller's `allocator` but freed from `self.allocator` by `Hub.heal` and
`Hub.deinit`. Every current caller passes the same allocator, so that half was
latent rather than observed.

## Reproduction

```zig
var hub = Hub.init(std.testing.allocator);
defer hub.deinit(tio);
try hub.drop(std.testing.allocator, tio, "node-a", "node-b");
try hub.drop(std.testing.allocator, tio, "node-a", "node-b");
```

Expected: the test passes. Actual, before the fix: the testing allocator
reports one leaked allocation of `"node-a\x00node-b"`.

## Root cause

`put` was read as "the map takes the key", which is only true when the key is
new. Nothing in the drop path distinguished the two cases, and no test dropped
the same edge twice.

## Resolution

`drop` builds a borrowed probe key, checks `dropped.contains`, and allocates the
owned key from `self.allocator` only when the edge is not already dropped. That
also makes the allocator that creates the key the one that `heal` and `deinit`
free it with.

## Verification

- New test `dropping the same edge twice does not leak the second key` in
  `src/net/transport.zig`: it fails on the pre-fix code under the testing
  allocator and passes after.
- `zig build test`.

## Follow-up

None. The other hub entry points allocate before the container insert already.

## References

- Code: `src/net/transport.zig` (`Hub.drop`, `Hub.heal`, `Hub.deinit`)
- Fix: this change
