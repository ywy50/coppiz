# Bug — The quote-aware TOML scanner ignores the `\"` escape and accepts unterminated quotes

## TL;DR

- **What failed:** `stripComment`/`parseStringArray` toggle quote state on every `"` with no escape handling, so a `\"` inside a value flips the state and a following `#` or `,` is misparsed; malformed arrays (`["a", "b]`, `["a" "b"]`) are accepted silently, producing garbage authority entries.
- **Impact:** Operator typos produce silently wrong config — under `configured` + `fallback = stall`, a garbage authority entry that matches no member leaves the cluster permanently leaderless.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

The sweep-1 fix made the scanner quote-aware but not escape-aware:

- `stripComment` (`local.zig:122-132`) and `parseStringArray` (`local.zig:295-324`) toggle `in_quotes` on every `"`. TOML basic strings support `\"`; a value like `"a\"b#c"` cuts at the `#` (the escaped quote flipped the state), and `"a\"b,c"` mis-splits at the comma.
- Unterminated quotes are accepted instead of refused: `["a", "b]` yields the authority entry `"b` (leading quote kept); `["a" "b"]` (missing comma) yields one item `a" "b`.

The parser's own contract is "deliberately strict" (unknown keys, bad scopes, bad hex all refuse by name); these malformed shapes pass and produce entries that can never match a member id — under `configured`/`stall` the cluster strands and (per the `applyJoin` rule) cannot self-heal.

## Reproduction

Not dynamically reproduced; statically certain. Feeding the three shapes above to `parseStringArray`/`stripComment` produces the wrong slices; no test covers escapes or malformed arrays.

## Root cause

Quote-state tracking that ignores escapes, plus no end-of-parse validation (balanced quotes, item boundaries).

## Resolution

Not yet fixed. Suggested direction: track the previous character for `\"`, and refuse unbalanced quotes/malformed items (`InvalidValue`) instead of emitting them. A regression test should cover `\"` inside quoted values and the two malformed-array shapes.

## Verification

- Static: both scanners read; the toggle-on-every-`"` behavior is unambiguous.

## Follow-up

None. Low priority (operator-typo trigger), but it sits in the same strictness contract the sweep already hardened twice.

## References

- Code: `src/config/local.zig:122-132` (`stripComment`), `:295-324` (`parseStringArray`), `:326-331` (`unquote`)
- Fix: none
