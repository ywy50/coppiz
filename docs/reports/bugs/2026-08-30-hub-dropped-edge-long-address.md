# Bug - the hub's dropped-edge check overflows its fixed buffer for long address pairs

## TL;DR

- **What failed:** `Hub.isDroppedLocked` (transport.zig) built the edge key in
  a fixed 512-byte stack buffer, while the drop side (`edgeKey`) uses an
  unbounded allocation. For a `from`+`to` pair longer than ~510 bytes the
  check reports "not dropped" and the dial proceeds through the partition.
- **Impact:** A partitioned edge is not enforced in the in-memory hub - the
  transport the simulator and the e2e tests use. Partition-based tests would
  silently pass without exercising the partition, and the simulator's merge
  scenarios would not actually partition.
- **Resolution:** Resolved - the check now builds the key with `allocPrint`,
  byte-for-byte identical to the drop side.

## Status

Resolved.

## Symptom and impact

`drop()` records the edge under `edgeKey` = `allocPrint("{s}\x00{s}")`, which
succeeds at any length. `isDroppedLocked` reconstructed the same key in a
512-byte `bufPrint`; on overflow it returned `false` - "not dropped" - so
`connectFn` dials through the partition. The existing drop test uses short
names, so the asymmetry was never exercised.

## Reproduction

Not dynamically reproduced before the fix; statically certain. A pair whose
combined length exceeds 512 bytes (e.g. two 300-byte addresses): `drop(from,
to)` succeeds, then `dialer.connect(to)` succeeds instead of refusing.

## Root cause

Two key constructions for the same edge: the drop side allocates, the check
side bounds - and the bound failure is silently treated as "not dropped".

## Resolution

Fixed: `isDroppedLocked` uses `allocPrint` (same format, same allocator as
`edgeKey`), so the keys always match. OOM on the check still degrades to
"not dropped", which is the safe direction for a test-only transport.

## Verification

- Regression test "a dropped edge with a long address pair still refuses
  dials" (src/net/transport.zig): two 300-byte addresses, the dial refuses
  after `drop`.
- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: src/net/transport.zig (`isDroppedLocked`, `edgeKey`)
- Fix: this report's resolving commit
