# Bug - an authority array item with a trailing bare token is stored verbatim, quotes included

## TL;DR

- **What failed:** `appendArrayItem` (config/local.zig) validates quotes but never
  requires the closing quote to be the item's last character. An item like
  `"a"x` passes every check, and `unquote` stores it verbatim - `"a"x` with
  both quote characters.
- **Impact:** A garbage authority entry enters the settings state. It can
  never resolve a member, so at n > 1 with `fallback = stall` every
  subsequent settings entry refuses (`AuthoritiesMatchNoMember`) - the same
  stranded-cluster failure mode as bug 2026-08-28-sweep3-ghost-authority-strand,
  reachable through a second route; at genesis (n = 1) it commits silently.
- **Resolution:** Resolved - the closing quote must now be the item's last
  character (after trimming); a trailing bare token is refused with
  `error.InvalidValue`.

## Status

Resolved.

## Symptom and impact

`leadership.authorities = ["a"x]` in the local config parses without error
and stores the entry `"a"x` (quote characters included). The check
"an item containing a quote must be exactly one fully-quoted string"
(local.zig, `appendArrayItem`'s contract) is not enforced: the loop verifies
the first quote is at position 0, the quotes balance, and the string is not
unterminated - but never that nothing follows the closing quote. `unquote`
then finds no quote at the end and returns the raw item.

## Reproduction

```toml
# coppiz.toml
[genesis]
leadership.authorities = ["a"x]
```

`parse` succeeds; the authorities list holds the single entry `"a"x`.
Expected: `error.InvalidValue`.

## Root cause

`appendArrayItem` (src/config/local.zig) validates the *interior* of a quoted
item (quote placement, balance, termination) but not its *extent*: a quoted
string followed by a bare token is indistinguishable, after the loop, from a
fully-quoted string, because only `quote_count` and `in_quotes` are
inspected. `unquote` is then called on a shape it does not recognize and
returns it unchanged.

## Resolution

Fixed: when an item contains quotes, the closing quote must be the item's
last character after trimming (`trimmed[trimmed.len - 1] == '"'`); otherwise
`error.InvalidValue`. Trailing whitespace after the closing quote stays
valid, matching `unquote`'s trim.

## Verification

- Regression tests in "malformed authority arrays are refused, not silently
  parsed" (src/config/local.zig): `["a"x]` refuses; `["a" ]` (trailing
  space) parses.
- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: src/config/local.zig (`appendArrayItem`, `unquote`)
- Fix: this report's resolving commit
