# Bug - the loop sim's fixed convergence window flakes: the threaded io's completion ordering is not fixed

## TL;DR

- **What failed:** `LoopWorld: a three-member partition elects a second
  leader and heals` asserted convergence after a fixed 30 ticks. The loop
  sim drives the nodes through a threaded io (async limit 8), whose
  completion ordering is not fixed, so the merge sometimes needs more ticks
  and the assertion fails.
- **Impact:** a flaky gate. The same binary + same seed passed on a rerun,
  proving the outcome depends on runtime timing, not the scenario. The test
  was added as the "deterministic" pin for PRD 0003's known issue; a flaky
  pin undermines it.
- **Resolution:** Resolved - the scenario polls convergence with a 200-tick
  bound instead of assuming 30 suffice.

## Status

Resolved.

## Symptom and impact

`zig build test` intermittently fails at
`assertConvergedAmong(&.{ 0, 1 })` in `src/sim/sim.zig` (the three-member
scenario): nodes 0 and 1's control folds differ after the 30-tick window.
Observed once in a full-suite run; rerunning the exact same binary with the
exact same seed passed all 236 tests.

## Reproduction

Intermittent. Run the root test binary repeatedly with different seeds; the
three-member scenario fails with some probability.

## Root cause

`LoopWorld` drives the nodes through `std.Io.Threaded` (sim.zig,
`.async_limit = .limited(8)`). The report's "no threads and no sockets"
claim is about the nodes' own loop threads - the io runtime itself is
threaded, so message-completion ordering varies between runs, and the tick
at which the merge finishes varies. A fixed tick count cannot bound a
variable finish time.

## Resolution

Fixed: the scenario polls `convergedAmong(&.{ 0, 1, 2 })` after the heal
write, ticking up to 200 times until the folds match, then asserts the
details (leaders, epoch, settings). The fixed-count assumption is gone; the
scenario's pins are unchanged.

## Verification

- Full `zig build test` green, `EXIT=0`.
- Two further full runs with fresh seeds green.

## Follow-up

The sim's "deterministic" claim is overstated while it runs on a threaded
io; a single-threaded io (or a fixed delivery order) would make the tick
counts load-bearing again. Not attempted here.

## References

- Code: src/sim/sim.zig (`LoopWorld`, the three-member scenario)
- Fix: this report's resolving commit
