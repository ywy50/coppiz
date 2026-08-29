# Bug - a scalar `coppiz.toml` value with unbalanced quotes is stored verbatim, quote included

## TL;DR

- **What failed:** `unquote` strips a value's quotes only when both ends
  carry one, and returned the value untouched otherwise. Every scalar key
  used it, so `data_dir = "/var/lib/coppiz` with the closing quote
  forgotten produced the directory name `"/var/lib/coppiz`.
- **Impact:** an operator typo becomes a silently wrong value rather than a
  startup error: a data directory, listen address, key-file path,
  `log.level`, `storage.fsync` value or peer address that begins or ends
  with a `"`. The node then creates or fails to find a path nobody meant,
  or reports a confusing downstream error.
- **Resolution:** fixed. One escape-aware quote-shape check now guards the
  scalar values as well as the array items, which already had it.

## Status

Resolved - 2026-08-30. Found by reading.

## Symptom and impact

`data_dir = "/var/lib/coppiz` (no closing quote) parses without error and
`Config.data_dir` is the 16 bytes `"/var/lib/coppiz`. The node then creates
a directory whose first character is a quote, beside the one the operator
meant. The same shape reaches `listen` (the address parse fails later, with
a diagnostic that names the quoted string), `member.key_file`, `log.level`,
`storage.fsync`, a peer `address`, and a peer `public_key` (there the
64-hex-character check catches it, so that key alone was already safe).

The reverse form (`data_dir = /var/lib/coppiz"`) and the trailing-junk form
(`data_dir = "/a" oops`) behave the same way.

## Reproduction

`a scalar value with unbalanced quotes is refused, not stored verbatim` in
`src/config/local.zig`, over eight cases across the six scalar keys and a
peer `address`.

- Expected: `error.InvalidValue`.
- Actual, before the fix: parse succeeds and the value keeps the quote.
  Confirmed by short-circuiting `unquoteChecked` back to the old
  both-ends-or-nothing rule and running `zig build test` (exit 1).

## Root cause

```zig
fn unquote(value: []const u8) []const u8 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return v;                                   // <- fails open
}
```

The function has no refusal path, so anything it does not recognise as a
quoted string is passed through as a bare token - including a value that is
quoted at one end only, which is not a bare token at all.

The array-item path had already been hardened twice against exactly this
class ([escapes and unterminated quotes](2026-08-29-toml-parser-escapes-and-unterminated.md),
[a trailing bare token](2026-08-30-config-array-trailing-token.md)), and the
second of those left a comment in `appendArrayItem` saying `unquote` "would
otherwise store it verbatim, quotes included". The scalars kept using
`unquote` directly, so the hardening never reached them: two paths, one
grammar, one of them checked.

An earlier report,
[the quote-unaware scanner](2026-08-28-toml-parser-quote-unaware.md), stated
that with the comment and comma scans fixed, "`unquote` is unchanged - its
both-ends-quoted rule now always sees intact values". That holds for a
correctly quoted line; it does not hold for a line the operator typed with
one quote.

## Resolution

The escape-aware check that `appendArrayItem` grew is factored into
`checkQuoteShape`, which accepts either no unescaped quote at all or exactly
one basic string filling the whole value: opening at index 0, closing at the
last byte, balanced. `unquoteChecked` runs it and then strips, and every
scalar key and the array items call it. The array behaviour is unchanged -
its own regression test still passes, and fails if the check is bypassed,
which is how the sharing is pinned.

Configs that were being mis-parsed now fail at startup with
`error.InvalidValue` naming the line, which is the intended layer for this
(PRD 0004: the local config is deliberately strict).

## Verification

- The new test (eight malformed cases, plus the well-formed and unquoted
  forms and a trailing space after the closing quote) passes with the fix.
- With `unquoteChecked` short-circuited to the old rule, both the new test
  and the existing `malformed authority arrays are refused, not silently
  parsed` fail - so one check now serves both paths.
- Full gate `zig build test` exit 0 on the branch.

## Follow-up

None. The remaining leniency in the parser (a bare unquoted value is still
accepted for every string key) is deliberate and unchanged.

## References

- Investigation: none
- Code: `src/config/local.zig` (`checkQuoteShape`, `unquoteChecked`,
  `parseTopLevel`, `parsePeerKey`, `parseValue`, `appendArrayItem`)
- Related: [2026-08-28 - the `coppiz.toml` subset parser is quote-unaware](2026-08-28-toml-parser-quote-unaware.md),
  [2026-08-29 - escapes and unterminated quotes](2026-08-29-toml-parser-escapes-and-unterminated.md),
  [2026-08-30 - an authority array item with a trailing bare token](2026-08-30-config-array-trailing-token.md)
