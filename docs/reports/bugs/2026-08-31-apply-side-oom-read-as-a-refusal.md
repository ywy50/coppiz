# Bug - an allocation failure while folding genesis or create_journal is read as a settings refusal

## TL;DR

- **What failed:** three apply-side call sites in `chain.zig` flattened every
  failure into `error.InvalidSettings`, `OutOfMemory` included -
  `applyGenesis`'s settings apply, and `create_journal`'s
  `SettingsState.initDefaults` plus its initial-settings apply.
- **Impact:** a refusal is a chain verdict every member reaches identically;
  OOM is one member's local condition. Reporting it as a refusal makes that
  one member reject a `genesis` or `create_journal` every other member
  accepted, and diverge from them silently and permanently - the failure mode
  the decode side was fixed for in
  [2026-08-28-sweep3-decode-oom-mapped-to-refusal](2026-08-28-sweep3-decode-oom-mapped-to-refusal.md).
- **Resolution:** fixed - all three go through `mapSettingsApplyError`, this
  file's own rule for the distinction, which was already written and simply
  not used at these sites.

## Status

Resolved 2026-08-31. Found by reading, while checking whether the decode-side
fix's claim about the apply side held.

## Symptom and impact

`chain.zig` separates two kinds of failure deliberately. A *refusal* names a
rule the entry broke; the broadcast and forward paths treat it as "the
chain's rules decided" and carry on. `OutOfMemory` is fatal: `registerEntry`
documents that an OOM mid-apply leaves the fold partially advanced and the
node cannot continue folding. The file carries three mappers for exactly
this - `decodeCatch`, `mapSettingsDecodeError`, `mapSettingsApplyError` -
and each passes `OutOfMemory` through.

The apply side of the two entry kinds that build settings from scratch did
not use them:

```
settings_fold.applyGenesis(&self.settings, payload.changes) catch
    return error.InvalidSettings;                                  // applyGenesis
...
var state = schema.SettingsState.initDefaults(self.allocator) catch
    return error.InvalidSettings;                                  // applyCreateJournalValidated
defer state.deinit();
settings_fold.applyGenesis(&state, payload.changes) catch return error.InvalidSettings;
```

All three callees allocate. `initDefaults` allocates a `Value` per schema
key; `applyGenesis` clones the whole state (a `string_list` key dupes each
item) before validating and committing. So an OOM in any of them surfaced as
`InvalidSettings`.

`2026-08-28-sweep3-decode-oom-mapped-to-refusal` fixed the *decode*
catch-sites of the same two entry kinds and asserted that "the apply side
does the opposite ... uses bare `try`". That was not true of these three
lines, which are the apply side of those same kinds.

## Reproduction

`src/journal/chain.zig`, test *an apply-side allocation failure is fatal,
never a settings refusal*: fold a `genesis` carrying a
`leadership.authorities` string_list, then a `create_journal`, with the fold
on a `std.testing.FailingAllocator`, sweeping `fail_index` from 0 to 119.

Expected: every index either succeeds or fails with `OutOfMemory`. Before the
fix the sweep reports `expected error.OutOfMemory, found
error.InvalidSettings` at the first index that lands inside
`settings_fold.applyGenesis`.

The index is swept rather than aimed at one allocation on purpose: what has
to hold is that *no* index anywhere in the fold yields a refusal, and an
aimed index stops testing that the moment the path allocates once more or
once less.

## Root cause

A `catch return <refusal>` on a call whose error set includes
`OutOfMemory` - the same shape as the decode-side bug, at the three sites
that fix did not cover. The mapper that encodes the correct policy already
existed beside them.

## Resolution

All three sites now use `mapSettingsApplyError`, which passes `OutOfMemory`
and `NotLiveChangeable` through and maps everything else to
`InvalidSettings`. `initDefaults`'s only other error, `BadSchemaDefault`, is
a schema bug a comptime-table test pins away; it keeps its old
`InvalidSettings` reading rather than gaining a new error for callers.

No refusal changes: every cross-key rule failure still reports
`InvalidSettings`, which the existing genesis and create_journal refusal
tests pin.

## Verification

- The new sweep fails on the unpatched fold with `expected
  error.OutOfMemory, found error.InvalidSettings` and passes with the
  mappers. Checked by reverting the three sites and re-running.
- The existing test *decode OutOfMemory propagates as fatal, never a
  refusal* and the genesis/create_journal refusal tests are unchanged.
- `zig build test` green on the branch.

## Follow-up

`applyCreateJournalValidated` has a second, unrelated defect on the same
error path - the duped journal name leaks when `journals.put` fails.
Reported and fixed separately.

## References

- Investigation: none
- Code: `src/journal/chain.zig` (`applyGenesis`,
  `applyCreateJournalValidated`, `mapSettingsApplyError`)
- Related: [2026-08-28-sweep3-decode-oom-mapped-to-refusal](2026-08-28-sweep3-decode-oom-mapped-to-refusal.md)
