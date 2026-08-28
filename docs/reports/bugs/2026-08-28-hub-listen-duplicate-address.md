# Bug — `Hub.listen` on a duplicate address silently replaces the first endpoint, contradicting its own contract

## TL;DR

- **What failed:** `listen` uses `endpoints.put`, which *overwrites* an existing value. A second `listen` on the same address leaks the first endpoint and its key dupe, routes every dial to the newest endpoint, and leaves the first listener's accept loop blocked forever — while the comment claims "the map's first entry wins".
- **Impact:** Test/simulator misconfiguration (two nodes on one address) silently misroutes connections and leaks memory; the first listener never accepts and never errors.
- **Resolution:** Still open. Statically validated (std `put` semantics verified).

## Status

Open.

## Symptom and impact

`transport.zig:460-462` documents "One listener per address; a second registration is refused by `connect` (the map's first entry wins)". The code at `:467` is `self.endpoints.put(allocator, dupe(address), ep)`. `AutoHashMap.put` on an existing key overwrites `value_ptr.*` with the new endpoint and drops the caller's key dupe; the old endpoint is never deinit'd/destroyed (`Hub.deinit` walks only the map's current values). After the overwrite:

- all dials to that address reach the new endpoint,
- the old endpoint's `pending`/`closed` state and any queued conns leak,
- the first listener's `acceptConn` blocks on its semaphore indefinitely (nothing posts it after the endpoint is orphaned).

## Reproduction

Not dynamically reproduced; statically certain. Two `hub.listen(test_alloc, "node-x")` calls: the second `put` overwrites the first endpoint. Grep shows every other `endpoints` access is a `get` (`connectFn`) or an iterate in `deinit`, none of which distinguishes first vs. last.

## Root cause

`AutoHashMap.put` is last-writer-wins; the contract comment assumes first-wins. The fix must either check `contains` and refuse a duplicate address, or deliberately implement last-writer-wins (closing the orphaned endpoint first).

## Resolution

Not yet fixed. Suggested direction: `if (self.endpoints.contains(address)) return error.AddressInUse;` (or close the previous endpoint's accept loop and drop it) before `put`. A regression test should call `listen` twice on the same address and assert the second is refused and the first still accepts.

## Verification

- Static: `put` overwrite semantics verified in the installed `std/hash_map.zig` (`putContext` → `getOrPutContext` clobbers `value_ptr.*`); the leak follows from `Hub.deinit`'s map walk.

## Follow-up

None — contained. Related hub defects reported separately (errdefer double-free, `readInto` interior free).

## References

- Code: `src/net/transport.zig:460-480` (`listen`), `:438-458` (`Hub.deinit`), `:562-605` (`connectFn`)
- Fix: none
