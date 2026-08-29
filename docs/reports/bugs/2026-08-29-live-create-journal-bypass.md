# Bug — The re-slotted `create_journal` variant is reachable live: any member can create journals via the forward path

## TL;DR

- **What failed:** The sweep-1 fix routed reslotted `create_journal` to a variant that skips the author check — but the reslotted/live decision is author-based inference (`chain.zig:311-312`), and `onForward` lets any member forward any entry. A member's self-signed `create_journal` is now accepted by every fold; before the fix it was refused `NotLeader`.
- **Impact:** The leader-only `create_journal` authorization ([PRD 0003](../../prds/0003-membership-and-leadership.md)) is bypassed: any member can grow the journal registry (bounded only by `max_journals` and the name/payload checks). Same inference silently converts a live non-leader control `settings`/`stale`/`checkpoint` into a no-op instead of a refusal.
- **Resolution:** Still open. Statically validated (fix regression).

## Status

Open. Introduced by `f401606` (`applyCreateJournalReslotted`).

## Symptom and impact

`create_journal` is documented as leader-authored (the live rule checks `checkAuthorIsLeader`, `chain.zig:335` + `:603-629` variant). The reslotted inference (`chain.zig:311-313`: any non-epoch entry whose author is not the current leader routes to `applyControlReslotted`) was designed for merge re-slots — where the author is the losing leader — but it fires identically for live entries. `onForward` (`node.zig:1592-1607`) has no kind or author filter: the leader slots any forwarded entry. A member signs a valid `create_journal` (its own key, fresh author_seq), forwards it; the leader's own fold accepts it via the reslotted path (its author ≠ leader), broadcasts, and every member folds the same way — the journal exists. Pre-fix, the reslotted case routed to the author-checking `applyCreateJournal` and refused.

## Reproduction

Not dynamically reproduced; statically certain. Trace:

1. Member M crafts `entry{ .kind = .create_journal, .author = M }`, signed with M's key, and sends `forward`.
2. The leader (`onForward`, `node.zig:1603`) slots it; `slotAndBroadcast` → `applyReplicated` → `applyControl`.
3. `chain.zig:312`: `reslotted_entry = author != leader` → true → `applyControlReslotted` → `.create_journal => applyCreateJournalReslotted` (`:377`) → `applyCreateJournalValidated` (`:595-601`) — **no author check**; only payload/name/max_journals/settings validation.
4. The journal is registered on every fold.

The same inference makes a live non-leader `settings`/`stale`/`checkpoint` control entry a silent no-op (`:378`) instead of the documented refusal — the sender is told nothing.

## Root cause

The reslotted path's precondition ("this is a merge re-slot") is inferred from authorship alone, which cannot distinguish a merge re-slot from a live forwarded entry. The fix relaxed the authorization without adding a way to tell the two apart.

## Resolution

Not yet fixed. Suggested direction: carry an explicit `reslotted` flag through the apply path (the node already knows whether it is merging — `applyReplicated`'s caller does), or re-check the kind/author on the live path (`onForward` should refuse non-`.data`/non-leader-authored entries). A regression test should forward a member-signed `create_journal` and expect a refusal, while a merge re-slot of the same kind still succeeds.

## Verification

- Static: inference (`chain.zig:311-313`), dispatch (`:377`), variant (`:595-601`, no author check), and `onForward` (`node.zig:1592-1607`, no kind filter) all verified by reading.

## Follow-up

The same inference gap weakens `settings`/`stale`/`checkpoint` authorization on the control chain (no-op instead of refusal). Worth fixing together.

## References

- Code: `src/journal/chain.zig:311-313`, `:374-381`, `:595-601`; `src/cluster/node.zig:1592-1607`
- Fix: none
