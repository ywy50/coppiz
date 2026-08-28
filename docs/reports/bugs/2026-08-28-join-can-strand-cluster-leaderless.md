# Bug — A join can silently strand the cluster leaderless: `configured` + `stall` with empty authorities

## TL;DR

- **What failed:** `validateState` allows `leadership.mode = configured` with an empty `authorities` list when `member_count <= 1` (the n=1 exception), but `applyJoin` never re-validates the state against the new member count. After the second member joins, the folded state violates `EmptyAuthoritiesNeedsFallback` — and `election.leader` returns `null` under `fallback = stall`, so no epoch can ever open.
- **Impact:** A cluster that was valid at n=1 silently becomes leaderless at n=2, and — because only the leader can author settings entries — unfixable once the founder is gone.
- **Resolution:** Still open. Statically validated (medium confidence it is unintended).

## Status

Open.

## Symptom and impact

The n=1 exception is deliberate ([PRD 0003](docs/prds/0003-membership-and-leadership.md): "list self, or empty list = self"); the `n = 1` early return in `election.leader` (`election.zig:161`) makes a lone member its own leader under every mode. But `validateState`'s `empty_ok` (`validate.zig:89-92`) is the *only* place the empty-authorities rule is enforced, and it sees `member_count` at settings-apply time only:

- At genesis (n=1): `configured` + `fallback = stall` + empty authorities is accepted.
- A `join` appends the member (`membership.zig:86-103`) and **does not** re-run `validateState`.
- At n=2 the folded state now violates the rule; `election.leader`'s configured path finds no authority, `best == null`, and `fallback = stall` returns `null` (`election.zig:176-178`) — `append` answers `no_leader`. The settings fix cannot be authored (only the fold's leader authors settings entries), so the cluster is permanently stalled.

## Reproduction

Not dynamically reproduced; statically certain:

1. Genesis with `leadership.mode = configured`, `authorities = []`, `fallback = stall`.
2. Admit a second member (join).
3. `leader(...)` at n=2 returns `null`; writes are refused forever.

A settings change at n=2 would be refused with `EmptyAuthoritiesNeedsFallback` (`applySettings` re-validates against the current count), which is exactly why the state never self-heals — and why it can only get there through the join path.

## Root cause

The `EmptyAuthoritiesNeedsFallback` invariant is checked only when settings are applied, not when membership changes. `applyJoin` mutates the member list without consulting `validateState`.

## Resolution

Not yet fixed. Suggested direction: re-validate the settings state in `applyJoin`/`applyLeave` against the new `member_count` (refusing the join or the state), or make the n=1 exception conditional on the cluster staying at n=1. A regression test should join a second member under the described genesis and assert the fold either refuses the join or the leader remains well-defined.

## Verification

- Static: `validateState` n=1 exception (`validate.zig:89-92`), `applyJoin` appends without validation (`membership.zig:86-103`), `election.leader` null under configured+stall (`election.zig:176-178`). All verified by reading the code.

## Follow-up

None. Medium confidence this is unintended rather than a known corner: the n=1 exception's own comment ("the case that makes a one-member cluster a complete cluster") implies the rule should hold as soon as the cluster grows.

## References

- Code: `src/settings/validate.zig:89-92`, `src/cluster/membership.zig:86-103`, `src/cluster/election.zig:157-181`
- Fix: none
