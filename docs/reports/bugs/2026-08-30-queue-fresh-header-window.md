# Bug - a crash in the fresh queue header window bricks the file with BadMagic forever

## TL;DR

- **What failed:** `Queue.open` on a file shorter than the header runs
  `setLength(header_len)` and then writes the header. A crash between the
  two leaves a file of exactly `header_len` zero bytes; the next open reads
  it, fails the magic check and returns `BadMagic` - permanently, since
  `len < header_len` is no longer true.
- **Impact:** the node refuses to open until the queue file is deleted by
  hand. The window is the first-ever open of a fresh directory, so narrow,
  but the refusal is permanent and unrepairable by the software.
- **Resolution:** Resolved - a file of exactly one header whose magic is
  wrong is rewritten as empty, as the store already does for a sub-header
  segment.

## Status

Resolved.

## Symptom and impact

`Queue.open` (queue.zig):

```zig
if (len < header_len) {
    try file.setLength(io, header_len);
    var header: [header_len]u8 = undefined;
    writeHeader(&header);
    try file.writePositionalAll(io, &header, 0);
    len = header_len;
} else {
    ... if magic != magic: return error.BadMagic ...
}
```

A crash (or a torn header write) between `setLength` and the write leaves
exactly `header_len` zero bytes. The next open takes the `else` branch
(len is not < header_len), reads zeros, and refuses with `BadMagic` on
every subsequent start. The store's equivalent window is handled
explicitly - a segment shorter than one header is dropped with "nothing to
load and nothing to lose" (store.zig) - the queue had no equivalent.

## Reproduction

Create a 6-byte zero `unslotted.queue` and open it: `BadMagic`.

## Root cause

The fresh-header path mutates the file in two steps, and the magic check
has no branch for "exactly one header with a wrong magic" - the only state
that step can produce.

## Resolution

Fixed: in the `else` branch, a file of exactly `header_len` whose magic is
wrong is the crash window and is rewritten as empty (the records scan then
finds none). A larger file with a bad magic is still genuine corruption and
is refused.

## Verification

- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: src/journal/queue.zig (`Queue.open`)
- Fix: this report's resolving commit
