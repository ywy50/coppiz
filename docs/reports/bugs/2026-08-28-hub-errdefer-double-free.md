# Bug — Hub `connectFn`/`listen` errdefer double-free on allocation failure

## TL;DR

- **What failed:** In `HubDialer.connectFn`, the `Pipe` is appended to `hub.pipes` *before* the two `PipeConn` allocations; the earlier errdefers stay armed, so an OOM in either `create` frees the pipe while the hub still owns it — `Hub.deinit` frees it again. `Hub.listen` has the same shape: the endpoint is put into the map before its later allocations, and an OOM in the `address` dupe destroys an endpoint the map still holds.
- **Impact:** Double-free/UB on the allocation-failure path of the hub transport (the in-memory transport used by the tests, the examples, and the simulator). Debug/GeneralPurposeAllocator panics; release builds corrupt the heap.
- **Resolution:** Still open. Statically validated.

## Status

Resolved — `connectFn`/`listen`/`dialer` perform every allocation before
touching the container, so no errdefer can free what the hub owns;
regression test drives every allocation with a failing allocator.

## Symptom and impact

`connectFn` (`transport.zig:562-605`):

```zig
const pipe = try hub_alloc.create(Pipe);
errdefer hub_alloc.destroy(pipe);                       // :573
pipe.* = .{ .out = ..., .in = ..., .from = dupe, .to = dupe };
errdefer { free(pipe.from); free(pipe.to); pipe.out.deinit(); pipe.in.deinit(); }  // :580-585
try self.hub.pipes.append(hub_alloc, pipe);             // :586  — hub now owns the pipe
const from_conn = try hub_alloc.create(PipeConn);       // :588  — OOM here
```

If `create(PipeConn)` (or the second one at `:595`) fails, the errdefers free `pipe.from`/`pipe.to`, deinit the directions, and destroy `pipe` — while `hub.pipes` still holds the pointer. `Hub.deinit` (`transport.zig:438-458`) later iterates `pipes`, frees `from`/`to`, deinits the directions, and destroys `pipe` again: double-free. In the window before deinit, `Hub.drop`/`isDropped` can also read the freed `from`/`to`.

`listen` (`transport.zig:463-480`) is the same shape: `endpoints.put(allocator, duped_key, ep)` at `:467` puts `ep` into the map, then `dupe(address)` at `:472` can fail; the errdefer at `:465` destroys `ep` while the map still owns it → `Hub.deinit` destroys it again.

## Reproduction

Not dynamically reproduced (needs a failing allocator at exactly the right point; `std.testing.FailingAllocator` with a fault at the `PipeConn`/`address` allocation would trigger it). Statically certain: the errdefer arms and the container insert order are unambiguous.

## Root cause

Container insertion happens before the remaining allocations, and the errdefers established before the insertion do not know the container now owns the object. The errdefer contract in both functions must be invalidated at the insertion point (e.g. via an `adopted` flag or by reordering the allocations before the container insert).

## Resolution

Fixed as suggested (allocate first, then insert):

- `connectFn`: the two `dupe`s and both `PipeConn` allocations happen
  before `hub.pipes.append`; only after every allocation succeeded does
  the hub own the pipe, so a failure anywhere earlier frees everything
  exactly once.
- `listen`: the endpoint, the map key and the `HubListener` (with its
  address) are allocated before `endpoints.put`; a failure before the put
  leaves the map untouched.
- `dialer` (same family, exposed by the new test): `errdefer
  allocator.destroy(d)` covers the `from` dupe.

Regression test ("hub connect and listen never double-free on allocation
failure"): runs one full hub lifecycle per failing allocation index
(`std.testing.FailingAllocator` over GPA) until a round succeeds — any
double-free or leak panics under the GPA. Verified to fail (double-free
panic) on the pre-fix ordering.

## Verification

- Static: both functions read; the armed errdefer + container-insert ordering verified line-by-line; `Hub.deinit`'s ownership walk confirmed.

## Follow-up

Related hub defects reported separately: duplicate-address `listen` overwrite/leak, and the `Direction.readInto` interior-pointer free (latent).

## References

- Code: `src/net/transport.zig:562-605` (`connectFn`), `:463-480` (`listen`), `:438-458` (`Hub.deinit`)
- Fix: `src/net/transport.zig` (`connectFn`, `listen`, `dialer`); regression test in the same file. `zig build test` green.
