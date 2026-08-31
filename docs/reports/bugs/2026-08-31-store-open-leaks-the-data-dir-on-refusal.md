# Bug - a refused `Store.open` leaks the data directory descriptor it was handed

## TL;DR

- **What failed:** `Store.open` documents that it takes ownership of the
  already-open `std.Io.Dir`, but only `deinit` ever closed it. Every refusal -
  the `LOCK` open, `error.AlreadyOpen`, the struct allocation, any `loadAll`
  failure - returned with the caller's descriptor still open and nobody left
  to close it.
- **Impact:** one leaked directory descriptor per refused open.
  `error.AlreadyOpen` is a first-class outcome the CLI matches on - it is how
  `append`, `read`, `head`, `members` and `doctor` decide to fall back to the
  wire - so every such command against a directory `coppiz serve` holds
  leaked one, as did every retry against a `Corrupt` or
  `UnsupportedVersion` directory.
- **Resolution:** fixed - ownership starts at the call, with an
  `errdefer data_dir.close(io)` at the top of `open`. `openPath`'s
  compensating errdefer and `journal.init`'s `dir_owned` handover moved with
  it, so nothing closes the handle twice.

## Status

Resolved 2026-08-31. Found by reading, then reproduced as a unit test.

## Symptom and impact

`Store` closes `data_dir` in `deinit` only:

```
pub fn deinit(self: *Store) void {
    ...
    self.data_dir.close(self.io);
```

and `open` has four refusal paths before that struct exists or is returned.
The two neighbours that get this right show what the contract was meant to
be: `Store.openPath` wraps its own call in `errdefer data_dir.close(io)`, and
`journal.init` carries a `dir_owned` flag it cleared only *after* `Store.open`
succeeded - added for
[2026-08-29-init-data-dir-double-close](2026-08-29-init-data-dir-double-close.md).
`journal.Node.open`, documented with the same ownership, had neither, so a
refusal there leaked.

The reachable path is ordinary operation, not an exotic failure:
`src/main.zig` matches `error.AlreadyOpen` from `openNode` in five commands
to decide "the directory is served, talk to the node over the wire". Each of
those attempts leaked one descriptor. A short-lived CLI process exits and the
kernel reclaims it, so the practical cost is bounded there; a long-lived host
that opens and retries (PRD 0005's supervisor case) is where it accumulates.

The store's own tests leaked it too - `env.openStore()` is passed into calls
expected to fail in the lock and corruption tests - which is why this stayed
invisible: `std.testing.allocator` counts bytes, not descriptors.

## Reproduction

`src/journal/store.zig`, test *a refused open closes the data directory
handle it was handed*.

POSIX hands out the lowest free descriptor, so the leak is observable without
counting descriptors or reading `/proc`:

1. Open a store and keep it, so the directory lock is held.
2. Open the data directory again; record `first.handle`.
3. `Store.open` on that handle refuses with `error.AlreadyOpen`.
4. Open the data directory once more.

Expected: the same handle number, because step 3 closed what it was given.
Actual, before the fix: `expected 13, found 14`.

## Root cause

An ownership contract stated in a doc comment and implemented only on the
success path. `open` acquires the handle's ownership at the call, but the
only close was in the destructor of an object the refusal paths never
produce.

## Resolution

`errdefer data_dir.close(io)` as the first statement of `Store.open`, so the
close covers every refusal and does not run on success (where `deinit` still
closes it).

Two call sites had been compensating for the gap and would now double-close,
so they moved in the same change:

- `Store.openPath` drops its own `errdefer data_dir.close(io)`.
- `journal.init` clears `dir_owned` *before* calling `Store.open` rather than
  after. The flag still guards the failures that happen before the call (the
  genesis validation and the member-key check), which is all it is for now.

A double close is the failure mode to avoid here rather than a leak: the
descriptor number is reusable immediately, so closing it twice can close a
file some other part of the process just opened
(2026-08-29-init-data-dir-double-close is that bug).

## Verification

- The new test fails on the unpatched store with `expected 13, found 14` and
  passes with the errdefer. Checked by deleting the one added line and
  re-running `zig test -Mroot=src/journal/store.zig`.
- The `init` tests (which drive both the pre-call refusals and the success
  path) and the lock/corruption tests are unchanged: 41/41 in
  `zig test -Mroot=src/journal/store.zig`.
- `zig build test` green on the branch.

## Follow-up

`journal.Node.open` needs no change: with `Store.open` owning the handle from
the call, its `errdefer st.deinit()` covers everything after. The known
gotcha that `Node.open` takes ownership of the passed handle is now true on
its refusal paths too, which is what it always claimed.

## References

- Investigation: none
- Code: `src/journal/store.zig` (`open`, `openPath`),
  `src/journal/journal.zig` (`init`)
- Related: [2026-08-29-init-data-dir-double-close](2026-08-29-init-data-dir-double-close.md),
  [2026-08-30-node-open-leaks-folded-journals](2026-08-30-node-open-leaks-folded-journals.md)
