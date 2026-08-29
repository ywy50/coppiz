# Investigation - write-path data flow: queue drains, replication re-encodes, and per-frame overhead

## TL;DR

- **Question:** what does one replicated write pay beyond the fold and the
  store write itself, on every member?
- **Finding:** the queue drain re-encoded every kept record per trim; a
  replicated slot was encoded twice on the leader (store + broadcast) and
  decoded then re-encoded on every follower (the wire bytes are already the
  store's on-disk format); forwarding double-allocated; the hub pushed every
  frame as two chunks; and a reconnect scanned the whole queue file even
  when it was empty.
- **Resolution:** implemented - the follower appends the wire record bytes
  verbatim (`Store.appendRecord`), the queue trim copies raw spans instead
  of re-encoding, forwarding builds the frame body in one allocation, the
  hub pushes header+body as one chunk, and `reforwardQueue` skips the scan
  on an empty queue.

## Status

Resolved and implemented (PR `perf/runtime-sweep/3-queue-wire`).

## Trigger and scope

A runtime-speedup sweep over `src/` (2026-08-29). This report covers the
per-record constant factors on the replication write path - the path every
acknowledged append travels in a cluster.

## Evidence

All observations are reads of the tree at `main` @ `ec18643`, verified
before implementation.

1. **Queue drain re-encodes per trim.** `Queue.remove` (`queue.zig:160-191`)
   scanned the file, `entry.decode`d each record, re-encoded the kept ones
   (`recordSize` + `encodeRecord` - a fresh CRC over the whole body) into a
   new buffer, and rewrote the file. Called from `applyReplicated` once per
   confirmed write (`journal.zig:590-592`). With k entries queued, k
   confirmations = k full-file rewrites, each re-encoding k-1 records whose
   bytes are already the exact on-disk form.
2. **Replicated slots are encoded 3–4× per member.** Leader:
   `applyReplicated` → `store.append` encodes the record (`store.zig:237-250`),
   then `broadcastToMembers` → `encodeSlot` → `segment.encodeRecord`
   encodes the same bytes again (`message.zig:337-341`). Follower:
   `decodeSlot` dupes and decodes the record (CRC check, `message.zig:343-360`),
   then `applyReplicated` → `store.append` re-encodes it. The wire record is
   the store format by construction - `decodeSlot`'s `record` field is the
   exact bytes the leader's store wrote. The same double-handling applies to
   sync pages (`onSyncReq` encodes each record into the page,
   `onSyncPage` decodes then re-encodes).
3. **`sendForward` double-allocates** (`node.zig:1725-1735`): an entry
   buffer, then `sendMessage` allocates the message body and copies.
4. **The hub pushes every frame as two chunks** (`transport.zig:351-358`):
   header and body each take a lock, a copy, and a semaphore post.
5. **`reforwardQueue` scans the whole queue file on every accepted member
   connection** (`node.zig:530-576`) even when nothing is queued.

## Hypotheses and tests

- **Hypothesis A - the follower can append the wire bytes verbatim.**
  `decodeSlot` validated the record (CRC + decode) and the bytes equal what
  `store.append` would have written. *Result:* supported - a new
  `Store.appendRecord(journal_id, position, record)` writes the raw span at
  the head offset and indexes by the (already validated) slot position.
  The merge re-slot paths (`doMergeControl`/`doMergeData`) still re-encode
  by necessity: the re-slotted record's slot differs from the wire's.
- **Hypothesis B - the queue trim can copy raw spans.** The kept bytes are
  unchanged on disk; the decode→re-encode round-trip is byte-identical.
  *Result:* supported - the match key comes from a header-only decode
  (`entry.decode` borrows; it allocates nothing), and the kept records are
  appended verbatim.
- **Hypothesis C - the hub reader accepts a combined header+body chunk.**
  `readInto` copies up to `dest.len` and re-bases the remainder
  (`transport.zig:269-302`). *Result:* supported - a combined chunk reads
  exactly like two consecutive chunks.

## Finding

The write path's per-record constant factors were dominated by redundant
encodes and copies of bytes that are already in the required form: on-disk,
on-wire, or both. All five fixes are same-semantics refactors.

## Resolution or handoff

- `Store.appendRecord` (`store.zig:379-405`) appends a validated record
  verbatim; `Node.applyReplicated` takes the optional wire record
  (`journal.zig:536-594`) and `onSlot`/`onSyncPage` pass it
  (`node.zig:1805, 2023`). Leader-authored and merge paths pass null.
- `Queue.remove` copies raw spans for kept records (`queue.zig:160-196`).
- `sendForward` builds the frame body (version | kind | length | entry) in
  one allocation (`node.zig:1731-1751`).
- `Direction.pushFramed` locks once and copies header+body into one chunk
  (`transport.zig:247-282`); the pipe's `sendFrame` uses it.
- `reforwardQueue` returns immediately on an empty queue (`node.zig:533-534`).

Verification: `zig build test` on this machine - 261/261 pass, exit 0;
the sole failure in the first run was the 100-column lint cap on one wrapped
call (fixed; `zig build lint` green). The replication e2e tests (broadcast,
backfill, merge) all pass, exercising the raw-record path.

## References

- Code: `src/journal/queue.zig`, `src/journal/store.zig`,
  `src/journal/journal.zig`, `src/cluster/node.zig`, `src/net/message.zig`,
  `src/net/transport.zig`
- Related sweep reports:
  [2026-08-29 - settings key resolution and checkpoint removal sets](2026-08-29-runtime-sweep-settings-checkpoint.md),
  [2026-08-29 - range reads and open-time discovery](2026-08-29-runtime-sweep-journal-read.md)
- Prior art: [2026-08-28 - making `zig build test` faster without dropping tests](2026-08-28-test-suite-quick-wins.md)
