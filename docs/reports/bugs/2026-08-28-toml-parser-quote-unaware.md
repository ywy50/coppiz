# Bug — The `coppiz.toml` subset parser is quote-unaware: `#` and `,` inside quoted values silently corrupt them

## TL;DR

- **What failed:** `stripComment` cuts a line at the first `#` even inside a quoted string, and `parseStringArray` splits on every `,` even inside a quoted item. Legal TOML values are silently misparsed into wrong values with no error.
- **Impact:** Operator-authored config (`coppiz.toml`) can silently produce a wrong `data_dir`/`listen` path or a wrong/broken `leadership.authorities` list. The failure surfaces only later, at open or join time, as a confusing symptom.
- **Resolution:** Still open. The `#` case is reproduced dynamically; the `,` case is verified statically (same root cause).

## Status

Resolved — `stripComment` and `parseStringArray` are quote-aware; two
regression tests cover `#` and `,` inside quoted values.

## Symptom and impact

- `data_dir = "/var/lib/coppiz#prod"` parses to the string `"/var/lib/coppiz` — the `#prod` tail is dropped **and** the leading quote is kept, because `unquote` only strips quotes when both ends are quoted. Validated by a standalone repro: `Config.parse` returns that string (the test's expected value `/var/lib/coppiz#prod` fails).
- `leadership.authorities = ["node-a,node-b"]` splits into two bogus entries `"node-a` and `node-b"` — both pass the length checks and reach the fold.

Both are legal TOML that the parser misreads without an error — exactly the "silently ignoring bad input" failure mode the module doc says it exists to prevent.

## Reproduction

```zig
var config = Config{ .allocator = test_alloc };
defer config.deinit();
try parse(test_alloc, "data_dir = \"/var/lib/coppiz#prod\"\n", &config);
// config.data_dir.? == "\"/var/lib/coppiz"  (leading quote kept, #prod dropped)
```

Expected: `/var/lib/coppiz#prod`. The comma case: `parseStringArray` on `["node-a,node-b"]` yields `"node-a` and `node-b"`.

## Root cause

`src/config/local.zig`:

- `stripComment` (`:118-121`) cuts at the first `#` regardless of quote context. A later `#` is only a comment in TOML outside a basic string.
- `parseStringArray` (`:271-289`) splits the array body on every `,` without tracking quote state, so a comma inside a quoted item splits it.

`unquote` (`:292-296`) then cannot repair the damage — it requires both ends quoted, so a value cut at `#` keeps its leading quote.

## Resolution

Fixed. `stripComment` now tracks a `"` toggle and cuts only at a `#`
outside a basic string; `parseStringArray` splits on commas only outside
quotes (tracking the same toggle), so a quoted item survives whole.
`unquote` is unchanged — with the scans fixed, its both-ends-quoted rule
now always sees intact values.

Regression tests (`config/local.zig`): `data_dir = "/var/lib/coppiz#prod"`
parses to `/var/lib/coppiz#prod` (was `"/var/lib/coppiz`), and
`leadership.authorities = ["node-a,node-b"]` yields exactly one item
`node-a,node-b` (was two bogus entries). Both verified red against the
old byte-wise scans.

## Verification

- Dynamic: standalone repro for the `#` case (parsed `data_dir` = `"/var/lib/coppiz`, expected `/var/lib/coppiz#prod`).
- Static: `parseStringArray` comma-split verified line-by-line; no test covers either case.

## Follow-up

The same scanner is shared by the CLI's `settings set` grammar (`parseValue`), so the misparse reaches the chain, not just local config.

## References

- Code: `src/config/local.zig:118-121` (`stripComment`), `:271-289` (`parseStringArray`), `:292-296` (`unquote`)
- Fix: `src/config/local.zig`; regression tests in the same file. `zig build test` green.
