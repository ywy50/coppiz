# Bug - a journal's fold leaks when the open is refused while building it

## TL;DR

- **What failed:** the three sites that build a `JournalState` guarded the
  24-byte box (`errdefer allocator.destroy(js)`) and nothing else. `js.fold`
  allocates the moment `FoldState.init` runs - a settings `Value` per schema
  key - and again for every record folded into it, so any failure between the
  init and the map insert leaked the whole fold.
- **Impact:** every reopen that refuses part-way through a data journal's
  fold leaks that journal's fold. The refusals are not hypothetical: this
  store has shipped several reopen refusals
  (`sweep3-pre-failover-settings-replay`, `merge-settle-bricks-reopen`,
  `retain-none-reopen-badprevhash`), and a host that retries the open - PRD
  0005's supervisor case - leaks once per attempt.
- **Resolution:** fixed - `errdefer js.fold.deinit()` beside the existing box
  errdefer, at all three sites.

## Status

Resolved 2026-08-31. Found by a failure-index sweep over `Node.open`.

## Symptom and impact

```
const js = try self.allocator.create(JournalState);
errdefer self.allocator.destroy(js);
js.fold = try chain.FoldState.init(self.allocator, false, journal_id);
try self.foldJournal(&js.fold, journal_id);   // may refuse
try self.journals.put(journal_id, js);        // may OOM
```

Three sites have this shape: `foldAll` (the reopen path),
`Node.createJournal`, and `applyReplicated`'s branch for a replicated
`create_journal`.

`Node.open`'s own errdefer cannot help. It walks `node.journals` and frees
what the map holds - the fix for
[2026-08-30-node-open-leaks-folded-journals](2026-08-30-node-open-leaks-folded-journals.md) -
and the in-flight `js` is not in the map yet. That is the distinction between
the two bugs: that one lost the folds already inserted, this one loses the
fold being built.

## Reproduction

`src/journal/journal.zig`, test *an open refused part-way through a journal's
fold owns nothing*: build a directory with two data journals holding records,
then sweep `std.testing.FailingAllocator`'s `fail_index` from 0 to 399 over
`Node.open`, asserting after every refusal that
`fa.allocations == fa.deallocations`.

Expected: equal at every index. Before the fix the sweep reports leaks from
`fail_index = 54` onward - the indices that land inside the second journal's
fold - as `allocs=54 deallocs=53`, and at 56 as `allocs=56 deallocs=54`,
where a fold that had folded a record leaks two allocations rather than one.

## Root cause

An owning field initialised after the errdefer that covers its container, with
no errdefer of its own.

## Resolution

`errdefer js.fold.deinit();` immediately after the `FoldState.init` at each of
the three sites. It is discharged when the enclosing scope exits normally -
in `foldAll` that is the end of one loop iteration, once `put` has taken
ownership - so a failure in a later journal cannot free a fold the map holds.

## Verification

- The sweep fails on the unpatched node at `fail_index = 54` and passes with
  the errdefers. Checked by removing them and re-running.
- 182/182 in a module test root over `src/journal/journal.zig`.
- `zig build test` green on the branch.

## Follow-up

The same sweep exposed a second, independent leak on the same path -
`loadJournal`'s segment-name dupe - reported and fixed alongside it
([2026-08-31-segment-name-dupe-leaks-on-append](2026-08-31-segment-name-dupe-leaks-on-append.md)).
The sweep could not go green until both were fixed.

## References

- Investigation: none
- Code: `src/journal/journal.zig` (`foldAll`, `createJournal`,
  `applyReplicated`)
- Related: [2026-08-30-node-open-leaks-folded-journals](2026-08-30-node-open-leaks-folded-journals.md)
