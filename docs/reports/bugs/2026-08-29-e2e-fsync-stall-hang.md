# Bug - `zig build test` randomly hangs: the e2e cluster tests fsync every record onto the host filesystem, and a stalled fsync blocks the suite forever

## TL;DR

- **What failed:** `zig build test` does not finish — the run hangs inside the
  TTL e2e test (`e2e (G4)`: three members remove the same set...). The test
  nodes fsync every record (`.fsync = .every`), their data dirs live in
  `.zig-cache/tmp` under the working tree — on this host, a btrfs volume —
  and the client's blocking `recvMessage` has no deadline, so a delayed or
  stalled fsync blocks the settings call (and the whole suite) forever.
- **Impact:** A hang wastes the entire test run (the process must be killed).
  The hang is seed/timing-dependent: `zig build test` completed in 65 s on a
  quiet machine and hung repeatedly under load. Any agent or CI that runs the
  gates can be stalled indefinitely.
- **Resolution:** Resolved - the e2e cluster test nodes now open with
  `.fsync = .never` (their data is throwaway; durability is not what they
  test), so no test fsync can stall the suite.

## Status

Resolved - the multi-node e2e harnesses (`triNodeInit` and the `e2e (b)`
nodes) open their stores with `fsync = .never`. Test data lives in
throwaway `std.testing.tmpDir` directories; the tested logic (replication,
merge, checkpoints, TTL) does not depend on durability. A per-record fsync
on every node both serialized the suite on the host disk and exposed it to
fsync stalls.

## Symptom and impact

`zig build test` occasionally never finishes. The last test to print is
`cluster.node.test.e2e (G4): three members remove the same set at the same
checkpoint slot, both retain values...` — the test's `ttlTrioInit` calls
`trio.a.client.settings("main", buf)` (node.zig), a blocking request whose
reply waits on the node's store append — which fsyncs. The client's
`recvMessage` (net/client.zig) blocks with no deadline, so any reply delay
hangs the whole test binary, and the build with it.

Reproduced on a tree with no local changes (only the shared baseline) using
`--seed=0x9c6f5f2d`: the run reached the G4 test and never progressed past
it (observed for 20+ minutes; multiple seeds and machines under load).

## Reproduction

```sh
zig build test            # hangs at e2e (G4) with some probability
```

Deterministic-ish reproduction (same baseline, seed chosen by observation):

```sh
zig build test && \
  ./.zig-cache/o/<root-test-binary> --seed=0x9c6f5f2d
```

Observed evidence during a hang (Linux, btrfs):

- A test thread blocked in `fsync` on a segment file under
  `.zig-cache/tmp/<random>/data/<journal>/seg-00000001` (the btrfs fsync
  never returned during the observation window).
- Other threads in futex waits (the io completion machinery waiting on that
  fsync) and the node loop threads running normally.
- `strace` during the hang: 16,061 `fsync`/`fdatasync` calls in the first
  minute, the last one unfinished.

## Root cause

Two facts compose into the hang:

1. `std.testing.tmpDir` (std/testing.zig) creates test data dirs under
   `.zig-cache/tmp` **relative to the working directory** — for this repo the
   btrfs volume `/home`. The store's default `fsync = .every` (store.zig)
   then syncs every appended record, every seal, every compaction rewrite.
   The TTL e2e tests append and checkpoint continuously, so the suite issues
   tens of thousands of fsyncs per minute, serialized on the host disk.
2. The wire client's `recvMessage` (net/client.zig) is a blocking receive
   with no deadline. `ttlTrioInit`'s settings call waits for the node's ack,
   which `authorControlFold` sends only after the store append (and its
   fsync) completes. A stalled or very slow fsync therefore blocks the
   client forever, and the test binary with it.

btrfs fsyncs can stall for long periods under load or on a busy subvolume
(this host runs several concurrent agent builds on the same volume), which
is why the hang is timing-dependent: a quiet machine passes in ~65 s, a
loaded one hangs.

## Resolution

Fixed: the multi-node e2e harnesses open their stores with
`fsync = .never` (node.zig `triNodeInit`, `e2e (b)`'s node_a/node_b). The
`e2e (c)`, G4 and G6 tests all use `triNodeInit`, so the whole cluster-e2e
suite no longer fsyncs. Nothing under test depends on durability — the
directories are throwaway tmpdirs, and no test simulates a crash mid-write
(the store's own open-time tests, which do exercise torn tails and seals,
keep their fsync policy). The single-node wire tests and the CLI remain on
the default.

The deeper hardening (a bounded receive deadline on the wire client, so a
silent peer can never hang a caller) is left as a follow-up: the CLI's
long-lived reads (follow mode) legitimately block, so a deadline needs an
opt-in policy rather than a blanket timeout.

## Verification

- Re-ran the previously-hanging reproduction
  (`.zig-cache/o/<root-test-binary> --seed=0x9c6f5f2d`) after the change:
  the G4/G6 tests complete and the binary finishes green.
- Full `zig build test` (tests + lint gates) green, `EXIT=0`.
- `strace` after the change shows no fsync calls from the e2e nodes.

## References

- Code: `src/cluster/node.zig` (`triNodeInit`, `ttlTrioInit`, `e2e (b)`),
  `src/net/client.zig` (`recvMessage`), `src/journal/store.zig` (fsync
  default), std/testing.zig (`tmpDir` → `.zig-cache/tmp`)
- Fix: this report's resolving commit
