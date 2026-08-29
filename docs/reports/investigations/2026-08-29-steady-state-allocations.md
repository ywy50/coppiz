# Investigation - steady-state allocation churn: heartbeats and per-tick views

## TL;DR

- **Question:** what does an idle cluster allocate per second, and which of
  it is trivially avoidable without changing behavior?
- **Finding:** every heartbeat interval allocated a fresh message body per
  member (`sendHeartbeat` -> `sendMessage`), the most frequent steady-state
  message in a cluster. The body is fixed-size, so a stack buffer removes
  the allocation outright.
- **Resolution:** implemented - `sendHeartbeat` builds the fixed-size body
  on the stack. The per-tick `viewsFor` allocations (node and simulator)
  were evaluated and left as-is: reusing a scratch buffer needs a borrow
  discipline for callers that consume the views, and the win is one small
  allocation per tick - noted, not worth the discipline risk.

## Status

Resolved for the heartbeat; the viewsFor scratch is explicitly rejected
(recorded here so it is not re-proposed blindly).

## Trigger and scope

The 2026-08-29 runtime sweep deferred this as findings item 21 ("heartbeat
body allocated per member per interval - tiny constant, most frequent
message - skip unless profiling shows it") and item 20 ("sim `viewsFor`
allocates per leader evaluation ... easy once #11 is in; not yet needed").
This pass evaluates both.

## Evidence

All observations are reads of the tree at `main` @ `527068e`, verified
before implementation.

1. **Heartbeat allocates per interval.** `sendHeartbeat`
   (`node.zig:1159-1167`) called `sendMessage`, which allocates
   `encodedLen(m)` (`node.zig:1120-1126`). The heartbeat body is fixed-size:
   `version | kind | heartbeat_len` where `heartbeat_len = 48`
   (`message.zig:437`). On a 3-member cluster at a 100 ms heartbeat cadence
   (the test fast-detection config), that is ~20 allocations/s/node just for
   heartbeats; the production default cadence is 1000 ms.
2. **The viewsFor allocations were considered and rejected.**
   `ClusterNode.viewsFor` (`node.zig:2610-2631`) allocates one
   `election.View` per fold member per tick (from `runElection`), and the
   simulator's `viewsFor` (`sim.zig:362-383`) does the same per leader
   evaluation. Callers consume the slice synchronously (`election.leader`),
   so a scratch buffer is mechanically safe today - but the returned slice
   borrows member data (`address`), and a future caller that retains the
   slice would read garbage after the next call. The win is one small
   allocation per tick per node; the borrow-discipline footgun is a real
   stability cost. Rejected; documented instead.

## Hypotheses and tests

- **Hypothesis A - a stack buffer serves the heartbeat.** The body is
  `[2 + heartbeat_len]u8`, comptime-known. *Result:* supported - the
  encoded bytes are identical to `sendMessage`'s.
- **Hypothesis B - the viewsFor scratch is safe.** It is, at the three
  current call sites (all immediate consumption), but only at them.
  *Result:* rejected on stability grounds, not correctness: the discipline
  is one retained-slice bug away from silent corruption, and the win is
  tiny.

## Finding

The heartbeat's per-interval allocation is pure waste with a zero-risk
removal; the per-tick viewsFor allocations are a real but small cost whose
removal would introduce a borrow-discipline hazard out of proportion to the
win.

## Resolution or handoff

- `sendHeartbeat` builds the fixed-size body on the stack
  (`node.zig:1159-1171`); identical wire bytes.
- viewsFor scratch: not implemented; this report records the rejection and
  the call-site audit (node: `runElection`, `epochAccepted`-adjacent check
  at `node.zig:2589`; sim: `leaderOf`'s callers - all consume immediately).

Verification: `zig build` and `zig build lint` clean; the cluster e2e tests
(which run at fast heartbeat cadences) exercise the new heartbeat path.

## References

- Code: `src/cluster/node.zig` (`sendHeartbeat`, `sendMessage`, `viewsFor`),
  `src/sim/sim.zig` (`viewsFor`), `src/net/message.zig` (`heartbeat_len`)
- Sweep: [2026-08-29 runtime speedup sweep findings](2026-08-29-runtime-sweep-findings.md)
  (items 20, 21)
