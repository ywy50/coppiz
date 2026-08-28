# Bug — `cmdServe` silently drops a malformed `[[peers]] public_key` from the allowlist

## TL;DR

- **What failed:** `cmdServe` builds the join allowlist with `if (hexKeyToBytes(hex)) |key| ...` — a `public_key` that isn't exactly 64 hex chars yields `null` and is silently skipped. The peer is still dialed as a seed, but its join is refused at hello with no diagnostic.
- **Impact:** A typo'd or truncated key in `coppiz.toml` passes config parsing and produces a refused join with zero feedback — in a security-relevant list, where the config layer is deliberately strict everywhere else.
- **Resolution:** Still open. Statically validated.

## Status

Resolved — `parsePeerKey` refuses a `public_key` that is not exactly 64
hex chars at parse time; regression test added.

## Symptom and impact

The strictness asymmetry: `parsePeerKey` (`config/local.zig:233-237`) accepts any string for `public_key` (its own test uses `public_key = "abcd"` as *valid* config), and config parsing refuses unknown keys by name everywhere else — but the key's *content* is never validated at parse time. `cmdServe` (`main.zig:247-249`) then silently drops an unparseable hex key:

```zig
if (peer.public_key) |hex| {
    if (hexKeyToBytes(hex)) |key| try allowlist.append(gpa, key);
}
```

The operator sees only a refused join at hello, with no error naming the bad key.

## Reproduction

Not dynamically reproduced; statically certain. Founder config with `[[peers]] public_key = "abcd"` (accepted by the parser), a joiner with that key dials; the allowlist omits it; hello is refused.

## Root cause

Key content is validated at consumption (silently) instead of at parse time (strictly). `hexKeyToBytes` returns `null` for a non-64-hex string, and the `if |key|` swallows that.

## Resolution

Fixed at the strict layer: `parsePeerKey` now validates the key's
content — exactly 64 hex chars, refused with `InvalidValue` otherwise —
so a malformed key cannot reach `cmdServe`'s allowlist at all. The
`if (hexKeyToBytes(hex)) |key|` in `cmdServe` remains as defense in
depth. (The existing "minimal config" test's `public_key = "abcd"`
sample was updated to a valid 64-hex key, since "abcd" is now — and
always was — an unparseable identity.)

Regression test ("a malformed peer public_key is refused at parse
time"): a short key, a 65-char key and a 64-char non-hex key are each
refused with `InvalidValue`.

## Verification

- Static: `main.zig:247-249` read; `parsePeerKey` accepts arbitrary strings; `hexKeyToBytes` null-returns on bad hex/length.

## Follow-up

None. Contained to the CLI's allowlist path.

## References

- Code: `src/main.zig:247-249` (`cmdServe` allowlist), `src/config/local.zig:233-237` (`parsePeerKey`)
- Fix: `src/config/local.zig` (`parsePeerKey`); regression test in the same file. `zig build test` green.
