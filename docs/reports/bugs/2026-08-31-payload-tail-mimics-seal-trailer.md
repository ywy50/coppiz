# Bug - an entry payload ending in seal-trailer bytes bricks every member's store

## TL;DR

- **What failed:** `sealStatus` decided a segment file was sealed from its
  last 38 bytes alone. A record ends with its entry's payload, so a payload
  whose last 38 bytes spell `CPST | version | 32 bytes` read as a seal
  trailer whose hash does not verify - which the open reports as
  `error.Corrupt`.
- **Impact:** one ordinary append bricks the data directory permanently.
  Every `coppiz` command that opens the store fails, `serve` cannot start,
  and `doctor` cannot report it. Replication writes the same record bytes on
  every member, so the whole group refuses to open after a restart. The
  bytes are chosen by whoever calls `append`; no crash, no corruption and no
  hostile peer is needed.
- **Resolution:** fixed - a trailer that does not verify is only evidence of
  damage when the records region excluding it decodes as a whole number of
  records. When the region *including* it decodes exactly instead, the 38
  bytes are payload and the segment is unsealed.

## Status

Resolved 2026-08-31. Found by reading `sealStatus`, then reproduced as a
unit test.

## Symptom and impact

A sealed segment is `header | records | CPST | version u16 | hash 32`, and
`sealStatus` looks for that trailer at the end of the file:

```
const records_len = file_len - segment.header_len - segment.seal_len;
const n = try file.readPositionalAll(self.io, &buf, segment.header_len + records_len);
const hash = segment.decodeSeal(&buf) catch return .absent;
...
if (!std.mem.eql(u8, &hash, &segment.recordsHash(records))) return .corrupt;
```

A record is `len | crc | slot | entry header | payload` (`segment.encodeRecord`),
so the last bytes of the last record are the last bytes of its payload, and a
payload is opaque to coppiz - `Node.append` and the wire append pass it
through. A 64-byte payload whose final 38 bytes are `segment.encodeSeal(...)`
therefore satisfies `decodeSeal` at exactly the offset `sealStatus` reads,
with a hash that cannot match the records region.

`loadJournal` turns `.corrupt` into `error.Corrupt` for the journal, which
`Store.open` propagates for the whole data directory. Nothing truncates or
repairs it, so the refusal is permanent, and the same false trailer also
makes `fileStartsChain` and `fileDecodesFully` misjudge the file.

This is a regression surface opened by the fix for
[2026-08-28-sweep3-hasseal-conflation](2026-08-28-sweep3-hasseal-conflation.md):
before it, a present-but-invalid trailer reported "no seal", so this input
scanned as records and the open survived. Making the status tri-state turned
the same false positive into a hard refusal - the correct call for real
damage, the wrong one here.

## Reproduction

`src/journal/store.zig`, test *an entry payload ending in seal-trailer bytes
does not brick the open*:

1. `createJournal`, then one `append` whose 64-byte payload ends in
   `segment.encodeSeal([_]u8{0xCD} ** 32, ...)`.
2. Close and reopen the store.

Expected: the store opens and `scanFrom` yields the one record with its
64-byte payload. Actual, before the fix: `env.openStore()` returns
`error.Corrupt`.

Arithmetic, for the record: the record is `8 + 168 + 164 + 64 = 404` bytes
and the file `54 + 404 = 458`, so the 38 bytes read at offset
`54 + 366 = 420` are exactly `payload[26..64]`.

## Root cause

The seal was recognised by position and magic only, with no cross-check
against the record structure it is supposed to follow. Payload bytes are
author-chosen, so "the file's last 38 bytes look like a trailer" is not
evidence that the file has one.

## Resolution

When the trailer's hash does not verify, the two readings of the file are
distinguished before either is believed:

- A genuine trailer is written past the last record, so the records region
  *excluding* it decodes as a whole number of records and the region
  *including* it does not (the trailer's first four bytes, `CPST`, read as a
  record length of about 1.4 GB, which `decodeRecord` refuses).
- A payload tail is the other way round: the whole region decodes exactly,
  and cutting 38 bytes off it truncates the last record.

So `sealStatus` now returns `.absent` when the whole region decodes exactly,
and `.corrupt` otherwise. The walk is factored out as `recordsDecodeExactly`,
which `fileDecodesFully` already needed and now shares.

A sealed segment whose trailer really was damaged still refuses: its region
including the trailer does not decode, which the pre-existing test *a sealed
segment whose seal hash does not verify refuses to open* pins.

## Verification

- The new test fails on the unpatched store with `FAIL (Corrupt)` and passes
  with the discriminator. Checked by deleting the three added lines and
  re-running `zig test -Mroot=src/journal/store.zig`.
- The seal-corruption test above still expects and gets `error.Corrupt`, and
  the sealing, compaction and generation-recovery tests are unchanged: 40/40
  in `zig test -Mroot=src/journal/store.zig`.
- `zig build test` green on the branch.

## Follow-up

The residual ambiguity is stated rather than closed: a segment whose last
record's payload ends in a false trailer *and* whose region does not decode
(a torn tail on the same file) still reports `.corrupt`. That is the
conservative reading - refusing beats truncating an acknowledged prefix
(PRD 0001 G3) - and it needs no author-chosen bytes to reach, so it is not a
new exposure.

Recording the seal out of band (a sibling file, or a header field written on
seal) would remove the ambiguity entirely, at the cost of a format change;
not proposed here.

## References

- Investigation: none
- Code: `src/journal/store.zig` (`sealStatus`, `recordsDecodeExactly`,
  `fileDecodesFully`), `src/journal/segment.zig` (`encodeRecord`,
  `encodeSeal`)
- Related: [2026-08-28-sweep3-hasseal-conflation](2026-08-28-sweep3-hasseal-conflation.md)
