# Investigation - the wire read and the local read still disagree, and one recorded fix cannot run

## TL;DR

- **Question:** did the fix for
  [2026-08-29-wire-read-drops-compacted-slots](../bugs/2026-08-29-wire-read-drops-compacted-slots.md)
  make `coppiz read` agree between a served and an unserved data directory?
- **Finding:** no. The branch that fix added to `onReadReq` is unreachable:
  `Node.readWhere` (then `readRange`) drops slot-only records *before* calling
  the callback, so the callback's `en == null` arm never runs. Both reads now
  hide removed slots, and `printRecord`'s `(removed)` arm in the CLI is
  unreachable for the same reason. A second, separate divergence is live:
  `coppiz head` over the wire is derived from a visibility-filtered read, so
  it answers with an older position - or `EmptyJournal` - where the local
  `head` returns the chain head.
- **Resolution:** no code change. Which behaviour is correct is not settled -
  the 2026-08-29 report and PRD 0002 G5 say opposite things - and the wire
  half of either answer is in `src/net/`/`src/cluster/`. This record is the
  handoff.

## Status

Investigating. It closes when the question under *Hypotheses and tests* -
"may a read show a removed slot at all?" - is answered, because both defects
below are the same answer applied twice.

## Trigger and scope

Found while reading `readRange` for an unrelated change, not from a failure
report. Scope is the read path only: `Node.readWhere` (`src/journal/journal.zig`),
`onReadReq` (`src/cluster/node.zig`), and `cmdHead` / `headViaWire` /
`printRecord` (`src/main.zig`). No replication, fold or storage behaviour is
involved.

## Evidence

**Observed, by reading the tree at `e45bba2`:**

1. `Node.readWhere`'s dispatch does `const e = en orelse return;` before any
   callback, with the comment "A slot-only record is a removed entry, which is
   invisible under every flag". So no caller of `readRange`, `readByAuthor`,
   `readByKind` or `readWhere` can ever see a null entry.

2. `onReadReq`'s callback (`src/cluster/node.zig`) opens with
   `const e = en orelse { ... encodeSlotOnlyRecord ... }`, citing bug
   2026-08-29-wire-read-drops-compacted-slots. It calls
   `self.node.readRange(...)`. Given (1), that arm cannot execute.

3. `printRecord` (`src/main.zig`) has an `else` arm printing `(removed)` for a
   null entry. Its two callers are the local read callback and the wire read
   callback. Given (1) and (2), neither can pass null.

4. `cmdHead` has two paths. Local: `node.head(jid)`, the fold's chain head.
   Wire: `headViaWire` runs `client.read(name, null, false, false, ...)` and
   keeps the last slot the callback saw.

**Inferred (not reproduced):** from (4), a journal whose newest entries are
stale or expired under default read flags answers `coppiz head` with the last
*visible* slot over the wire and the true head locally; a journal all of whose
entries are hidden answers `error.EmptyJournal` over the wire and a position
locally. Reproducing it needs a running `serve` plus TTL settings, which is a
process-level e2e; it is stated as inference on purpose.

**Also observed:** the 2026-08-29 report's *Symptom and impact* asserts that
"`coppiz read` against a locked data dir (local read) renders them
`(removed)`". That was not true of the tree when this was checked, and (1)'s
comment states the opposite policy. One of the two is wrong; the report's own
*Reproduction* says "Not dynamically reproduced; statically certain".

## Hypotheses and tests

- *The fix was reverted.* Rejected: the branch is present in `onReadReq`, with
  its bug reference intact. It is dead, not missing.

- *`readRange` changed after the fix, making it dead.* Not established. The
  filtering comment and the fix could have been written in either order; `git
  log -S` was not run for this record. Either way the current tree has both,
  and the combination is inert.

- *The wire path calls something other than `readRange`.* Rejected by reading:
  `onReadReq` calls `self.node.readRange`.

- **The open question, which neither defect can be fixed without answering:**
  may a read show a removed slot at all?
  - *No* is what `readWhere` implements and what PRD 0002 G5 argues -
    "`include_*` shows them **until removal**", i.e. removal is the end of
    visibility. Under that answer the correct change is to delete the dead
    arm in `onReadReq` and the dead arm in `printRecord`, and the 2026-08-29
    report's premise was wrong.
  - *Yes* is what the 2026-08-29 report assumed and what `printRecord`'s
    `(removed)` arm was written for; a consumer walking positions can then
    tell "this slot existed and its bytes are gone" from "this position never
    existed". Under that answer `readWhere` must emit slot-only records and
    the `include_*` flags need a third state, because a `retain = header`
    removal still has an entry header while a `retain = none` removal does
    not - so the two `retain` values would show differently unless the fold's
    `removed` flag drives the decision rather than the record's shape.

  That is a decision with two candidates and a real consequence either way,
  which makes it RFC-shaped rather than something to settle inside a bug fix.
  It is not filed as an RFC here because it belongs with
  [RFC 0018](../../rfcs/0018-read-consistency.md)'s subject matter and should
  either extend that RFC or arrive with a recommendation; this record is the
  evidence either would cite.

## Finding

Two distinct defects, one cause each:

1. **A recorded fix that cannot run.** `onReadReq`'s slot-only arm is
   unreachable because the filtering it compensates for happens one layer
   below it, inside `readWhere`. The consequence is not "wire reads drop
   compacted slots while local reads show them" (the 2026-08-29 report's
   claim) but "both drop them, and one file carries dead code and a bug
   reference implying otherwise". Nothing is lost or corrupted; the cost is
   that the next reader trusts a fix that is inert.

2. **`coppiz head` is not the chain head over the wire.** The wire has no
   `head` request, so `headViaWire` reconstructs one from a read - which means
   it inherits the read's visibility filter, and pages the whole journal to
   answer a one-value question. The local path does not. Same command, same
   directory, two answers depending on whether a node happens to be serving,
   which is exactly what the "every command falls back to the wire when the
   directory is locked" design promises not to do.

## Resolution or handoff

No change made. The smallest next steps, in dependency order:

1. Answer the visibility question above (extend RFC 0018, or a new RFC with a
   recommendation). Until then, changing either side risks making the two
   agree on the wrong thing - and making `readWhere` emit slot-only records is
   a behaviour change for every embedded host, not just the CLI.
2. Given "removed slots are invisible": delete the dead arm in `onReadReq` and
   the `(removed)` arm in `printRecord`, and reopen
   2026-08-29-wire-read-drops-compacted-slots to record that its premise did
   not hold. Both edits are in `src/cluster/` and `src/main.zig`.
3. Independently of (1): give the wire a `head` request, so `cmdHead` asks the
   question it means instead of deriving it. That is a `src/net/message.zig`
   plus `src/cluster/node.zig` change and needs no answer to the visibility
   question. The in-territory half-measure - passing `include_stale = true,
   include_expired = true` in `headViaWire` - was deliberately *not* taken: it
   would close the stale/expired gap and leave the removed-slot gap, i.e.
   make the divergence rarer without removing it, which is harder to find
   later.

A regression check for (3) is a process-level e2e: `serve`, set
`ttl.enforce = all` with a 1 ms `ttl.default_ms` on a journal, append, then
compare `coppiz head` against the same directory's head after the serve
stops.

## References

- Bug: [2026-08-29-wire-read-drops-compacted-slots](../bugs/2026-08-29-wire-read-drops-compacted-slots.md)
  (states the opposite premise; not reopened here, since which premise is
  right is the open question)
- Code: `src/journal/journal.zig` (`readWhere`), `src/cluster/node.zig`
  (`onReadReq`), `src/main.zig` (`cmdHead`, `headViaWire`, `printRecord`)
- Related: [RFC 0018](../../rfcs/0018-read-consistency.md),
  [PRD 0002](../../prds/0002-ttl-and-staleness.md) G5
