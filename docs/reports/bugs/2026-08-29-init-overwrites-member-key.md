# Bug - `coppiz init` on an already-initialized directory replaces `member.key` and writes a second control chain

## TL;DR

- **What failed:** `journal.init` had no "is this directory already bootstrapped?" guard, and `writeMemberKey` deliberately reopens an existing `member.key` and overwrites it. A second `coppiz init` therefore replaced the founder's identity and appended a second `genesis` under a fresh control-journal id.
- **Impact:** The member's derived id changes, so it is no longer the member its own control fold records: `leader()` never equals `member_id` again and `admit` returns `not_leader` forever. A single-founder cluster is stranded with no way back, because the old secret key is gone.
- **Resolution:** Fixed - `init` refuses a directory that already carries a member key or any journal, with `already_initialized`, before writing anything.

## Status

Resolved.

## Symptom and impact

`src/main.zig` `cmdInit` created the directory when absent and called
`journal.init` unconditionally. `journal.init`'s own docstring stated the
precondition it did not enforce ("The store must be freshly opened on an empty
directory"), and it wrote the key as its first side effect:

```zig
var keypair = crypto.sign.Ed25519.KeyPair.generate(io);
try writeMemberKey(allocator, io, data_dir, keypair);   // before any check
const st = try store.Store.open(allocator, io, data_dir, .{});
```

`writeMemberKey` falls back to `openFile(..., .read_write)` on
`PathAlreadyExists`, so an existing key is replaced rather than refused.

Two outcomes, both bad:

- **Directory served by a running node.** `Store.open` fails `AlreadyOpen`, so
  the command reports an error - after the key has already been replaced. The
  running node keeps the old key in memory and keeps working; the next
  restart derives a different member id from the new file and folds a chain
  in which that id is not a member.
- **Directory not served.** The command succeeds. `st.createJournal` runs with
  a fresh random `control_id`, so the store now holds two control journals.
  `foldAll` picks the control journal by "first record is a genesis" and takes
  whichever it iterates first, which is hash-order over the journal ids.

## Reproduction

```sh
coppiz init --dir ./data --journal main
coppiz init --dir ./data --journal main    # succeeded before the fix
```

Expected: the second command refuses and changes nothing. Actual (before the
fix): it succeeded, `member.key` held different bytes, and the store held two
journal directories whose first record was a `genesis`.

The regression test "init refuses an already-initialized directory instead of
replacing its key" (`src/journal/journal.zig`) reads `member.key` before and
after the second `init` and asserts the bytes are unchanged.

## Root cause

`init` had no precondition check, and `writeMemberKey` was written for the
"create or reuse" shape used by `coppiz serve` (which legitimately writes a
key onto a key-less joiner directory) rather than the "create only" shape
`init` needs.

## Resolution

`journal.init` now, in order: validates the initial settings, refuses when
`member.key` exists, opens the store, and refuses when the store already
holds any journal. Only then does it generate and write the key. Both
refusals are `error.AlreadyInitialized` and neither writes anything.

The second check matters on its own: a directory whose key was removed by
hand still holds its journals, and a second genesis there would put two
control chains in one store.

`coppiz serve` is unaffected: it writes a key only when none exists and never
calls `init`.

## Verification

- `zig build test` green on the branch.
- The regression test above fails on the unfixed `init` (the second call
  succeeds and the key bytes differ).

## Follow-up

`init` is still not atomic: a failure between the store write and the
`create_journal` append leaves a control chain with a genesis and no first
journal. That is recoverable (the chain is valid and `coppiz doctor` reports
it), unlike the identity loss this report covers, so it is not addressed here.

## References

- Investigation: none
- Code: `src/journal/journal.zig` (`init`, `writeMemberKey`,
  `memberKeyExists`), `src/journal/store.zig` (`journalCount`),
  `src/main.zig` (`cmdInit`)
- Related: [2026-08-29-init-data-dir-double-close](2026-08-29-init-data-dir-double-close.md)
