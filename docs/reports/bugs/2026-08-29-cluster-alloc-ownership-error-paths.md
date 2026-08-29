# Bug - three cluster allocations are owned by nobody when the step after them fails

## TL;DR

- **What failed:** Three places allocate and then do something that can fail, with no path that frees or rolls back what was already allocated. `membership.applyJoin` orphans the duped address and can leave a member in the fold that the chain has no entry for; `ClusterNode.bootstrapDial` leaks a seed key when the same address is named twice; `ClusterNode.init` frees only the struct when its own setup fails.
- **Impact:** The `applyJoin` partial mutation is the serious one: a member that survives a refused `join` is a divergence from every peer whose allocation succeeded, and the fold no longer matches the chain it was folded from. The other two are leaks.
- **Resolution:** Fixed. Each allocation now has an owner on every path out.

## Status

Resolved.

## Symptom and impact

### 1. `applyJoin` mutates the fold before it can still fail

`src/cluster/membership.zig`, before the fix:

```zig
try fold.members.append(fold.allocator, .{
    ...
    .address = try fold.allocator.dupe(u8, payload.address),
});
...
const views = try fold.memberViews(fold.allocator, null);
defer fold.allocator.free(views);
validate.validateState(&fold.settings, fold.memberCount(), views) catch {
    removeMember(fold, payload.member_id);
    return error.InvalidSettings;
};
```

Two holes on the same few lines:

- The `dupe` is an argument, so it runs *before* `append`. When `append`
  itself fails, the address is unreachable and leaked.
- `validateState`'s refusal rolls the member back. `memberViews`' failure
  does not, and `chain.applyControl` never reaches `registerEntry` on an
  error, so the fold ends up holding a member for which no entry exists.
  Every peer whose allocation succeeded folds the same chain to a different
  member table, and nothing later reconciles them.

### 2. `bootstrapDial` leaks a repeated seed address

```zig
const owned = self.allocator.dupe(u8, address) catch return;
self.seed_retry.put(self.allocator, owned, 0) catch { ... };
```

`StringHashMapUnmanaged.put` keeps the key it already holds, so the second
`dupe` of an address named twice in `[[peers]]` is handed to nobody.
`ClusterNode.deinit` frees the stored keys, and this one is not among them.
This is the same mechanism as
[`2026-08-29-hub-drop-duplicate-edge-key-leak.md`](2026-08-29-hub-drop-duplicate-edge-key-leak.md)
at a second call site.

### 3. `ClusterNode.init`'s errdefer covers only the struct

```zig
errdefer allocator.destroy(self);
try self.syncMembersFromFold();
try self.resetMySeq();
```

`syncMembersFromFold` fills the members map with duped addresses and can
schedule seed retries; `resetMySeq` fills `my_seq`. `deinit` is the only
thing that frees any of it, and a failure here destroys the struct without
calling it.

## Reproduction

New test `a join that runs out of memory leaves the fold exactly as it found
it` in `src/cluster/membership.zig`. The fold is built on a
`std.testing.FailingAllocator` with failures still disabled, then each of the
join's own allocations is failed in turn. On every induced failure the test
asserts `error.OutOfMemory`, that the fold still has exactly the founder, and
that the second member is absent; the testing allocator behind the failing one
catches the leak. The sweep asserts that it induced at least one failure, so it
cannot pass vacuously.

New test `a seed peer named twice does not leak the second retry key` in
`src/cluster/node.zig`: a node whose `seed_peers` are `{"peer-a", "peer-a",
"peer-b"}` calls `bootstrapDial` and must end with two retry entries and no
leak.

The `init` errdefer is OOM-only and shares the mechanism of the first; it is
fixed without a dedicated test rather than left with a wrong comment.

## Root cause

One shape, three times: allocate, then do a fallible thing, with the
intervening state owned by neither the caller nor the container. Zig's
`errdefer` exists for exactly this and was applied to the last fallible step
in these functions but not to the ones before it. The `applyJoin` case is the
one that matters because the unowned thing is not memory but *fold state*,
and a fold that disagrees with its chain is not recoverable by freeing
anything.

## Resolution

- `applyJoin` splits the dupe out so its failure path is nameable, guards it
  with an `errdefer` until `append` takes it, and then hands over to
  `errdefer removeMember(...)` for everything after. `validateState`'s
  explicit rollback is gone because the errdefer now covers it.
- `bootstrapDial` probes `seed_retry.contains(address)` and only allocates a
  key the map will actually take.
- `ClusterNode.init`'s `errdefer` calls `self.deinit()`, which is what frees
  the maps its two setup calls build.

## Verification

- Both new tests above.
- `zig build test --summary all` green.

## Follow-up

`ClusterNode.deinit` being safe to call on a partly-initialized struct is now
load-bearing for `init`'s errdefer. It is: every field has a default, and
`init` sets `self.*` before the first fallible call, so every map `deinit`
sees is at least `.empty`.

## References

- Code: `src/cluster/membership.zig` (`applyJoin`), `src/cluster/node.zig` (`bootstrapDial`, `init`, `deinit`)
- Same mechanism elsewhere: [`2026-08-29-hub-drop-duplicate-edge-key-leak.md`](2026-08-29-hub-drop-duplicate-edge-key-leak.md), [`2026-08-29-merge-deferred-leaves-double-free.md`](2026-08-29-merge-deferred-leaves-double-free.md)
- Fix: this change
