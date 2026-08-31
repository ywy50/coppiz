# Bug - an allocation failure while judging an epoch is read as a partition

## TL;DR

- **What failed:** `epochAccepted` folded `viewsFor`'s `OutOfMemory` into its
  boolean verdict, so a transient allocation failure returned `false` -
  which both callers read as "my liveness view elects someone else" and
  answer with `onDivergence`.
- **Impact:** a member that fails one small allocation while judging a
  perfectly valid epoch declares a partition against a peer it agrees with.
  `onDivergence` is the entry point to `becomeLoser`, which truncates a
  committed suffix of this member's chain.
- **Resolution:** fixed - the verdict is now `error{OutOfMemory}!bool` and
  the allocation failure propagates instead of being answered as
  disagreement.

## Status

Resolved 2026-08-31. Found by reading, not from an incident: no occurrence
in a log is known, and none is claimed here.

## Symptom and impact

`epochAccepted` (`src/cluster/node.zig`) answers one question: is the leader
this `epoch` entry claims the leader my own liveness view elects? A `false`
is a meaningful protocol answer - it means the two members genuinely
disagree about who leads, which is the definition of a partition here - and
both call sites act on it:

```
if (en.kind == .epoch and !self.epochAccepted(&en, &m.sl)) {
    ...
    try self.onDivergence(conn_id, payload.leader, m.sl.epoch);
```

one on the live broadcast path (`onSlot`) and one on the backfill path
(`onSyncPage`).

The judgement needs one heap allocation: `viewsFor` builds a
`[]election.View` sized by the member count. That allocation's failure was
mapped onto the same `false`:

```
const views = self.viewsFor() catch return false;
```

So an `OutOfMemory` and a real disagreement were indistinguishable to the
caller. The consequence is not a dropped frame: `onDivergence` computes a
survivor and, when this member loses, `becomeLoser` truncates this member's
chain back to the common tail. A committed suffix is discarded because an
allocation failed.

## Reproduction

The unit test added with the fix, in `src/cluster/node.zig`:

- build a one-member `ClusterNode`, whose own view elects itself;
- craft a *live* `epoch` entry - one past the fold's current number, so
  neither of `epochAccepted`'s early returns answers it - naming this
  member as leader;
- judge it once with a working allocator: accepted, as it should be;
- swap `cn.allocator` for `std.testing.failing_allocator` and judge the
  identical entry again.

Expected: the verdict is unavailable, and says so. Actual, before the fix:

```
error: 'cluster.node.test.an allocation failure while judging an epoch is
       not a partition' failed: expected error.OutOfMemory, found false
```

The same entry that was accepted a line earlier is rejected, and a rejection
is what `onDivergence` acts on.

## Root cause

A three-valued outcome - accepted, rejected, could-not-tell - was encoded in
a two-valued return. `catch return false` is safe when `false` means "drop
this and move on"; here `false` is an assertion about cluster state that
drives a destructive path. The decode failure on the line above it is
correctly `false`: a malformed payload *is* a protocol violation, and the
callers handle it separately by closing the connection. Only the allocation
failure was miscategorised.

## Resolution

`epochAccepted` returns `error{OutOfMemory}!bool`; `viewsFor`'s failure
propagates with `try`, and both call sites became `!try
self.epochAccepted(...)`. Both already return `!void`, so the error joins the
loop's existing error path rather than being answered as a protocol fact.

No behaviour changes when memory is available: the accepted/rejected verdict
is computed exactly as before.

## Verification

- The test above fails on the unfixed line for the intended reason (quoted
  in *Reproduction*) and passes with the fix.
- `zig build test` green on the branch: `Build Summary: 25/25 steps
  succeeded; 336/336 tests passed`. The same command on the branch's base
  (`origin/main`, 849a45e) is green at 335 tests, so the delta is this test.

## Follow-up

`viewsFor` has two other callers (`src/cluster/node.zig:1208`, `:3206`);
both already propagate its error with `try`. This was the only site that
swallowed it. No other `catch return false` over an allocating call remains
in `node.zig`.
