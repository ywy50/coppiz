# ADR 0008 - `storage.fsync` governs the queue; the redundant clear barrier is dropped

## Status

Accepted - 2026-08-29.

## Context

The append hot path issued three fsync barriers per acknowledged write:
`queue.append`, `store.append`, and `queue.clear`, with the queue's two
barriers unconditional - `storage.fsync` (local config, `every` | `batched`
| `never`) was threaded into the store only, so a user choosing `.never`
(or `.batched`) still paid two queue fsyncs per append. The knob did not
mean what it said for a third of the write path.

The 2026-08-29 runtime sweep measured the mechanism ([RFC 0003](../rfcs/0003-append-durability-fsync-policy.md));
this machine's strace confirms it: one append pays 3 fsyncs under `.every`,
and 2 under both `.batched` and `.never`.

The safety of dropping the queue's barriers rests on two facts, both
verified by reading:

- the queue entry is drained (`remove` per entry, or `clear` for the whole
  queue) only after the slot is stored (`journal.zig` applyReplicated), so
  an entry present in the queue is either unslotted (it must survive a
  crash to be re-slotted) or already-slotted (a crash that loses the trim
  redelivers it, and the fold's dedup accepts it as a no-op -
  `journal.zig` re-slot path);
- `setLength` is atomic and a torn tail truncates at open, so a crash
  during a drain leaves either the full queue (idempotent replay) or a
  shorter one whose removed records replay as no-ops.

## Decision

Option A of [RFC 0003](../rfcs/0003-append-durability-fsync-policy.md):

1. The queue honors `storage.fsync`: `append` syncs under `.every` and
   `.batched` (per append, until a flush point exists - the RFC's
   conservative default), never under `.never`.
2. The drain barriers - `remove` (the per-entry trim on the cluster append
   path) and `clear` (the whole-queue drain) - never sync: the trimmed
   entry's slot is already stored, and a lost trim replays an idempotent
   no-op. (The RFC's mechanism description named only `clear`; the
   append-path drain is `remove` - the same argument covers both.)

Under `.every` (the default, and PRD 0001 G3's durability contract), an
acknowledged write keeps the store barrier - durability is unchanged. The
knob now means the same thing on every component it governs.

## Consequences

- Barrier count per append: 3 → 2 under `.every`; 2 → 1 under `.batched`;
  2 → 0 under `.never` (strace-verified on this machine, 2026-08-29).
- The queue gains an `fsync` field; `Queue.open` takes the policy from
  `Node.open`'s options; the queue's tests pass `.every` explicitly.

## Alternatives considered

The RFC's Option B (keep the queue always-durable, document the gap) was
rejected: it keeps a documented lie and the redundant barrier. Option C
(durability-aware acks on the wire) was rejected: a wire change for a
batching promise the loop does not yet deliver.

## References

- RFC: [0003 - what does `storage.fsync` govern?](../rfcs/0003-append-durability-fsync-policy.md)
- Evidence: [2026-08-29 - runtime speedup sweep findings](../reports/investigations/2026-08-29-runtime-sweep-findings.md)
  and its write-path report; strace barrier counts per knob (this machine,
  2026-08-29)
- Code: `src/journal/queue.zig` (`open`, `append`, `clear`),
  `src/journal/journal.zig` (`Node.open` options)
