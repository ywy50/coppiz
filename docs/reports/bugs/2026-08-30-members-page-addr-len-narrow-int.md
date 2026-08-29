# Bug - a `members_page` address at the u16 maximum aborts the node before admission

## TL;DR

- **What failed:** `decodeMembersPage`'s per-member cursor advance,
  `off += 34 + addr_len`, computed in `addr_len`'s own `u16`. A maximal
  65535-byte address overflows the sum.
- **Impact:** an abort in a safe build, reachable by any peer that can
  connect to the listen port - no key, no genesis hash, no allowlist entry.
  In a release build the cursor wraps to 33 and a well-formed page is
  refused as `InvalidLength`.
- **Resolution:** fixed. The length field is read as `usize`.

## Status

Resolved. Found by reading `src/net/message.zig`; no investigation record.

## Symptom and impact

`decodeMembersPage` walks the page one member at a time:

```zig
var off: usize = 26;
while (done < count) : (done += 1) {
    if (off + 34 > bytes.len) return error.InvalidLength;
    const addr_len = std.mem.readInt(u16, bytes[off + 32 ..][0..2], .little);
    if (off + 34 + addr_len > bytes.len) return error.InvalidLength;
    ...
    off += 34 + addr_len;
}
```

The two bounds checks are safe: `off` is `usize` and appears leftmost, so
`off + 34` promotes and `addr_len` widens with it. The cursor advance is not.
`34 + addr_len` is a standalone binary expression, the `comptime_int` literal
coerces *down* to `u16`, and the sum overflows for `addr_len >= 65502`.
Verified directly under the declared toolchain:

```
$ zig run /tmp/x.zig
error: overflow of integer type 'u16' with value '65569'
    off += 34 + al;
           ~~~^~~~
```

The trigger is a well-formed frame, not a malformed one: `count = 1` and one
member whose address length is 65535 makes a 65,597-byte body, comfortably
under `framing.max_body_bytes` (17 MiB), so the frame reader hands it over.

Reachability is the worst in the file. `ClusterNode.onFrame` calls
`message.decode` *before* `frameAllowed`, and `frameAllowed` returns `true`
for `.members_page` regardless of role, so the abort needs nothing but a TCP
connection to the listen port.

## Reproduction

`a members_page address at the u16 maximum decodes, not overflows the cursor`
in `src/net/message.zig`. It builds the 65,597-byte body by hand and calls
the real `message.decode`.

Before the fix:

```
error: 'net.message.test.a members_page address at the u16 maximum decodes,
not overflows the cursor' terminated with signal ABRT with stderr:
       thread 7220598 panic: integer overflow
       ... in decodeMembersPage
```

After the fix the page decodes and the test asserts the member's address is
65535 bytes long - the non-vacuous half, so a fix that simply refused the
page would not pass.

## Root cause

The narrow-int sweep recorded in
[2026-08-29 - wire length checks compute in the peer's own narrow int
type](2026-08-29-wire-length-checks-narrow-int.md) fixed eleven decoders and
concluded, in prose:

> `decodeMembersPage` is the one decoder in the file that was already right:
> it declares `var off: usize = 26`, so every later sum promotes to `usize`.

That is true of the two comparisons and false of the compound assignment,
where `off` is not an operand of the inner sum. `decodeMembersPage` is also
the only decoder whose length field is nested *per element* rather than read
once against the fixed header, which is why its own `var off: usize` reads as
sufficient at a glance.

Neither existing test could catch it. The max-length regression test
enumerates ten kinds and omits `members_page`, the one kind that needs a body
larger than its minimum to reach its length field. The in-file fuzz test
fills a 512-byte buffer, so it cannot produce a 65,597-byte body at all.

## Resolution

`const addr_len: usize = ...` at the read, which is where every sibling
decoder in the file already puts the annotation. The bounds checks are
unchanged in behaviour; only the cursor advance changes, from a `u16` sum to
a `usize` one.

## Verification

- The new test aborts with `panic: integer overflow` in `decodeMembersPage`
  before the change and passes after.
- `zig build test` green on the branch.

## Follow-up

The max-length regression test still omits `members_page`; the new test
covers the same ground for this kind, but a future decoder with a nested
per-element length would not be caught by either. The fuzz test's 512-byte
buffer remains a structural blind spot for any field that needs a large body.

## References

- Code: `src/net/message.zig` (`decodeMembersPage`)
- Related: [2026-08-29 - wire length checks compute in the peer's own narrow
  int type](2026-08-29-wire-length-checks-narrow-int.md), whose sweep
  excluded this decoder
- Fix: this PR
