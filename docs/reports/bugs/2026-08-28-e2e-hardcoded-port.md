# Bug — One process-level e2e test hardcodes a port, defeating the pid-derived port design

## TL;DR

- **What failed:** The test-suite header (`main.zig:1040-1043`) derives test ports from the test pid "so an aborted earlier run … or a parallel checkout cannot collide on fixed ports", and `testAddr` implements that — but the test "members and doctor reach a serving node over the wire" hardcodes `"127.0.0.1:17431"` instead of `testAddr(...)`.
- **Impact:** A stale `serve` from an aborted run (the exact case the design exists for) or a concurrent checkout on the same machine binds 17431 → `tcpListen` fails → flaky test.
- **Resolution:** Still open. Statically validated.

## Status

Resolved — the literal is replaced with `testAddr(7)` (the pid-derived
scheme); one-line fix.

## Symptom and impact

One test in the suite contradicts the design that the surrounding tests depend on. It is a flakiness source exactly when the pid-derived scheme is needed.

## Reproduction

Not dynamically reproduced; statically certain. `src/main.zig:1320` uses `"127.0.0.1:17431"`; every other process-level test uses `testAddr(offset)` (`main.zig:1045-1049`). With a stale process on 17431 (or a parallel checkout), the test's `tcpListen` fails.

## Root cause

The hardcoded port was introduced (likely as a shortcut) after the pid-derived design was written; it bypasses the collision-avoidance the header documents.

## Resolution

Fixed: `src/main.zig:1320` now uses `try testAddr(7)` (a previously
unused offset) exactly like every other process-level test, so the test
cannot collide on the fixed port `17431` with a stale serve from an
aborted run or a parallel checkout. The address is freed like the
others.

## Verification

- Static: literal vs. `testAddr` usage across the suite verified by grep.

## Follow-up

None.

## References

- Code: `src/main.zig:1320`, design note `:1040-1043`, helper `:1045-1049`
- Fix: `src/main.zig:1320` (`testAddr(7)`). `zig build test` green (all 13 process-level tests pass).
