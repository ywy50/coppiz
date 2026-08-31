# Bug - The re-slotted `create_journal` variant is reachable live: any member can create journals via the forward path

## TL;DR

- **What failed:** The sweep-1 fix routed reslotted `create_journal` to a variant that skips the author check - but the reslotted/live decision is author-based inference (`chain.zig:311-312`), and `onForward` lets any member forward any entry. A member's self-signed `create_journal` is now accepted by every fold; before the fix it was refused `NotLeader`.
- **Impact:** The leader-only `create_journal` authorization ([PRD 0003](../../prds/0003-membership-and-leadership.md)) is bypassed: any member can grow the journal registry (bounded only by `max_journals` and the name/payload checks). Same inference silently converts a live non-leader control `settings`/`stale`/`checkpoint` into a no-op instead of a refusal.
- **Resolution:** Fixed. Re-verified in the tree 2026-08-31: `onForward` refuses every non-`data` kind. The "joins excepted" clause below described work that did not exist until 2026-08-31; it does now, and behind the leader's own admission policy - see the Status note.

## Status

Resolved. Introduced by `f401606` (`applyCreateJournalReslotted`).

**Verified in the tree 2026-08-31.** This record was one of the 29 flipped
to `Resolved` by `8893ae1` ("docs(reports): mark the sweep fixes resolved
(#116)"), a commit that touched 29 report files and no source file, and it
kept a TL;DR reading "Still open" and a `Fix: none` reference line. Both
were stale, not evidence: the fix is present.

`onForward` (`src/cluster/node.zig`) refuses any entry whose kind is not
`data`, naming this report in the comment, so a member's self-signed
`create_journal` never reaches the fold's re-slot inference.

One clause of the Resolution below was ahead of the tree: joins were **not**
excepted when this record was written, and were still refused as of
`34404d5`. The follower-admitter defect that needs the exception
(2026-08-28-sweep3-follower-admitter-join-fails) was fixed on 2026-08-31,
and `.join` is now excepted - but only behind `joinAdmissible`, which
re-runs the leader's own admission policy over the forwarded payload. A
regression test, "the forward path's join exception admits nothing the
leader's policy refuses", pins that a forwarded `create_journal` still
closes the connection.

## Symptom and impact

`create_journal` is documented as leader-authored (the live rule checks
`checkAuthorIsLeader`, `chain.zig:335` + `:603-629` variant). The reslotted
inference (`chain.zig:311-313`: any non-epoch entry whose author is not the
current leader routes to `applyControlReslotted`) was designed for merge
re-slots - where the author is the losing leader - but it fires identically
for live entries.

`onForward` (`node.zig:1592-1607`) has no kind or
author filter: the leader slots any forwarded entry. A member signs a valid
`create_journal` (its own key, fresh author_seq), forwards it; the leader's
own fold accepts it via the reslotted path (its author ≠ leader), broadcasts,
and every member folds the same way - the journal exists. Pre-fix, the
reslotted case routed to the author-checking `applyCreateJournal` and
refused.

## Reproduction

Not dynamically reproduced; statically certain. Trace:

1. Member M crafts `entry{ .kind = .create_journal, .author = M }`, signed with M's key, and sends `forward`.
2. The leader (`onForward`, `node.zig:1603`) slots it; `slotAndBroadcast` → `applyReplicated` → `applyControl`.
3. `chain.zig:312`: `reslotted_entry = author != leader` → true → `applyControlReslotted` → `.create_journal => applyCreateJournalReslotted` (`:377`) → `applyCreateJournalValidated` (`:595-601`) - **no author check**; only payload/name/max_journals/settings validation.
4. The journal is registered on every fold.

The same inference makes a live non-leader `settings`/`stale`/`checkpoint` control entry a silent no-op (`:378`) instead of the documented refusal - the sender is told nothing.

## Root cause

The reslotted path's precondition ("this is a merge re-slot") is inferred from authorship alone, which cannot distinguish a merge re-slot from a live forwarded entry. The fix relaxed the authorization without adding a way to tell the two apart.

## Resolution

Fixed: `onForward` refuses non-data entries (joins excepted for the follower-admitter path), closing the re-slot-inference bypass that let a member create journals or no-op past settings.

## Verification

- Static: inference (`chain.zig:311-313`), dispatch (`:377`), variant (`:595-601`, no author check), and `onForward` (`node.zig:1592-1607`, no kind filter) all verified by reading.

## Follow-up

The same inference gap weakens `settings`/`stale`/`checkpoint` authorization on the control chain (no-op instead of refusal). Worth fixing together.

## References

- Code: `src/journal/chain.zig:311-313`, `:374-381`, `:595-601`; `src/cluster/node.zig:1592-1607`
- Fix: in the tree - `src/cluster/node.zig` `onForward` (the kind filter) and `joinAdmissible` (the `.join` exception, 2026-08-31)
