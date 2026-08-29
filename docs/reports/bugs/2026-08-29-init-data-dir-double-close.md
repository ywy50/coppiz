# Bug - `cmdInit`'s `errdefer data_dir.close(io)` closes a descriptor the store already closed

## TL;DR

- **What failed:** `cmdInit` kept an `errdefer data_dir.close(io)` over a call to `journal.init`, which hands the same handle to `Store.open` and then closes it with a plain `defer st.deinit()` - on the failure path too. Any error after `Store.open` succeeded closed the descriptor twice.
- **Impact:** The second close targets a descriptor number the process may already have reused, so it can close an unrelated file. Latent: it needs `init` to fail after the store is open.
- **Resolution:** Fixed - `journal.init` owns the handle on every path and the caller no longer closes it.

## Status

Resolved.

## Symptom and impact

`src/main.zig` `cmdInit`:

```zig
var data_dir = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
errdefer data_dir.close(io);
try journal.init(gpa, io, data_dir, cfg.genesis.items, first_journal, &journal.wallClock);
```

`src/journal/journal.zig` `init`:

```zig
const st = try store.Store.open(allocator, io, data_dir, .{});
defer st.deinit();      // plain defer: also runs when init returns an error
```

and `Store.deinit` ends with `self.data_dir.close(self.io);`. The ownership is
asymmetric, which is what makes it easy to miss: when `Store.open` itself
fails it does *not* close the handle, so the caller's `errdefer` is right on
that one path and wrong on every path after it.

## Reproduction

Not dynamically reproduced; statically certain from the two ownership rules
above. The failure paths after `Store.open` are the payload allocation, the
`createJournal` / `append` store writes (ENOSPC, EACCES) and
`encodeCreateJournalPayload` refusing an over-long `--journal` name with
`settings_too_large` - the last of which is reachable from the command line.

## Root cause

`journal.init` never documented who owns `data_dir`, and its `defer
st.deinit()` silently transferred ownership at the point `Store.open`
succeeded rather than at the point `init` returned.

## Resolution

`journal.init` now states in its docstring that it takes ownership of
`data_dir` on every path, and enforces it: a `dir_owned` flag arms an
`errdefer data_dir.close(io)` for the refusals that run before `Store.open`
and is cleared the moment the store adopts the handle. `cmdInit` no longer
closes it. The three call sites in the test suite already relied on this
shape (none of them closes the handle it passes).

## Verification

- `zig build test` green on the branch, including the regression test that
  drives a post-`Store.open` failure (`init` with an over-long journal name)
  and then reopens the directory as a node, proving the handle is still
  usable and the chain intact.

## Follow-up

The same "who owns the handle" question applies to `openNode`, `cmdServe`,
`cmdDoctor` and `cmdAdmit`, which pass `data_dir` to `Node.open` and leak it
when `Store.open` fails with `AlreadyOpen` - the common wire-fallback path.
That is a leak in a process about to exit, not a double close, and is left
open.

## References

- Investigation: none
- Code: `src/main.zig` (`cmdInit`), `src/journal/journal.zig` (`init`),
  `src/journal/store.zig` (`deinit`)
- Related: [2026-08-29-init-overwrites-member-key](2026-08-29-init-overwrites-member-key.md),
  [2026-08-28-sweep3-truncate-errdefer-double-close](2026-08-28-sweep3-truncate-errdefer-double-close.md)
