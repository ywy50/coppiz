# Bug - The quote-aware TOML scanner ignores the `\"` escape and accepts unterminated quotes

## TL;DR

- **What failed:** `stripComment`/`parseStringArray` toggle quote state on every `"` with no escape handling, so a `\"` inside a value flips the state and a following `#` or `,` is misparsed; malformed arrays (`["a", "b]`, `["a" "b"]`) are accepted silently, producing garbage authority entries.
- **Impact:** Operator typos produce silently wrong config - under `configured` + `fallback = stall`, a garbage authority entry that matches no member leaves the cluster permanently leaderless.
- **Resolution:** Fixed in `773af4d` (2026-08-29), with the scalar half hardened again in `fd48e6a`. Statically validated; the fix is confirmed present in the tree by the 2026-08-31 audit below.

## Status

Resolved 2026-08-29 (audited 2026-08-31).

## Symptom and impact

The sweep-1 fix made the scanner quote-aware but not escape-aware:

- `stripComment` (`local.zig:122-132`) and `parseStringArray` (`local.zig:295-324`) toggle `in_quotes` on every `"`. TOML basic strings support `\"`; a value like `"a\"b#c"` cuts at the `#` (the escaped quote flipped the state), and `"a\"b,c"` mis-splits at the comma.
- Unterminated quotes are accepted instead of refused: `["a", "b]` yields the authority entry `"b` (leading quote kept); `["a" "b"]` (missing comma) yields one item `a" "b`.

The parser's own contract is "deliberately strict" (unknown keys, bad scopes, bad hex all refuse by name); these malformed shapes pass and produce entries that can never match a member id - under `configured`/`stall` the cluster strands and (per the `applyJoin` rule) cannot self-heal.

## Reproduction

Not dynamically reproduced; statically certain. Feeding the three shapes above to `parseStringArray`/`stripComment` produces the wrong slices; no test covers escapes or malformed arrays.

## Root cause

Quote-state tracking that ignores escapes, plus no end-of-parse validation (balanced quotes, item boundaries).

## Resolution

Fixed: `stripComment`/`parseStringArray` track backslash parity so an escaped quote does not toggle the string state, and malformed array items (unterminated quotes, mis-nested pairs) are refused; regression tests cover `\"` and the malformed shapes.

## Correction - what the 2026-08-31 audit checked

`8893ae1` ("docs(reports): mark the sweep fixes resolved", 2026-08-29) flipped
this report's `## Status` to `Resolved` and rewrote its `## Resolution` in a
commit that touched 29 report files and no source. It left the `## TL;DR`
resolution bullet reading "Still open" and the `- Fix:` reference reading
"none", so the record contradicted itself and gave a reader no way to tell
whether the fix existed. Five other reports flipped by that commit were
audited on 2026-08-31 and found to have no fix in the tree at all.

This one does. Audited 2026-08-31 by reading the shipped code and the history
of the symbol the resolution credits. The fix landed in `773af4d`, whose
subject ("fix(wire): a read of an unknown journal refuses with a named error
(#90)") names only the last of the twelve fixes it carries. `8893ae1` has that
commit as an ancestor, so its status flip was right - only the two metadata
lines were left behind.

`stripComment` and `parseStringArray` both track `backslash_parity`, and each
array item goes through `appendArrayItem` into `unquoteChecked` into
`checkQuoteShape`, which refuses an unterminated or mis-nested quote. The
tests *an escaped quote inside a quoted value does not end the string* and
*malformed authority arrays are refused, not silently parsed* cover it. The
scalar half of the same strictness contract was hardened later again, in
`fd48e6a`.

Only the `## TL;DR` resolution bullet, the `## Status` line and the `- Fix:`
reference were corrected; the symptom, reproduction, root cause and resolution
are unchanged.

## Verification

- Static: both scanners read; the toggle-on-every-`"` behavior is unambiguous.

## Follow-up

None. Low priority (operator-typo trigger), but it sits in the same strictness contract the sweep already hardened twice.

## References

- Code: `src/config/local.zig:122-132` (`stripComment`), `:295-324` (`parseStringArray`), `:326-331` (`unquote`)
- Fix: `773af4d` (PR #90); the scalar half of the same strictness contract
  in `fd48e6a` (bug
  [2026-08-30-toml-scalar-unbalanced-quote](2026-08-30-toml-scalar-unbalanced-quote.md))
