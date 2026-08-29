# Bug - A non-empty authority list that matches no member strands the cluster leaderless (the empty-list fix covered only `len == 0`)

## TL;DR

- **What failed:** `validateState` refuses only an *empty* authority list. A non-empty list whose entries match no member - a 64-hex public key pasted instead of a 32-hex id, a dead hostname, any non-matching string - passes genesis and every join; once the cluster grows past n=1, `leader()` finds no authority and `fallback = stall` returns `null`.
- **Impact:** The cluster strands permanently - and, since only the leader can author settings entries, the bad list can never be corrected online. The same no-self-heal class the empty-list fix (2026-08-28-join-can-strand-cluster-leaderless) closed.
- **Resolution:** Resolved - `validateState` now takes the member table and refuses a non-empty authority list that resolves to no member under the same conditions the empty-list rule uses (n > 1, no seniority fallback).

## Status

Resolved - `validateState` (validate.zig) gained a `members` parameter and
the `AuthoritiesMatchNoMember` rule: a non-empty authority list naming no
member is refused exactly when the empty-list rule fires (n > 1,
`fallback = stall`), so the n = 1 pre-provisioning carve-out is unchanged.
The rule runs at the settings-apply hook (`applySettings`), the join hook
(`applyJoin`, mirroring the empty-list fix), and - new - the live `leave`
hook (`applyLeaveChecked`), which the empty rule could never violate since a
leave only shrinks the count. The merge re-slot leave path skips the check:
a refusal there would abort the heal with the merge entry already on the
survivor's chain.

## Symptom and impact

`validateState` (`validate.zig:89-96`): `empty_ok` guards `list.len == 0` only. `authorityIndex` (`election.zig:81-85`) matches a verbatim address or a 32-hex id - anything else is silently skipped when `leader()` scans for an authority. At genesis n=1 the lone member leads itself (`election.zig:161`), so the bad list is invisible; `applyJoin` re-validates only the *count* (`membership.zig:113`) - a non-empty garbage list passes. At n≥2: `leader()` (`election.zig:176-179`) finds no live authority → `null` → `append` answers `no_leader` forever; no diagnostic anywhere.

## Reproduction

Not dynamically reproduced; statically certain. Genesis with `leadership.authorities = ["ghost.example"]` (or a 64-char hex key), then a second member joins.

## Root cause

The validation checks list *emptiness*, not list *resolvability*: an authority entry that matches no member is indistinguishable from a typo'd entry at validation time, and nothing refuses it.

## Resolution

Fixed: `validateState` (validate.zig) takes the member table
(`validate.MemberView`, built by `chain.FoldState.memberViews`) and returns
`error.AuthoritiesMatchNoMember` when a non-empty authority list resolves to
no member and the state would strand (`!empty_ok` - the same n = 1 and
seniority-fallback exceptions the empty-list rule uses, so pre-provisioning
a future member at genesis still works).

The rule is enforced at the settings-apply hook (`applySettings`, both
scopes - journal scope is inert, it carries no leadership keys), the join
hook (`applyJoin`, the empty-list fix's own hook), and the live leave hook
(`applyLeaveChecked` - a leave can remove the last resolvable authority,
which the empty rule can never do). The merge re-slot leave path skips the
check so a heal cannot abort on it.

Regression tests: validate.zig's ghost-list test, membership.zig's
ghost-join refusal and last-authority-leave refusal.

## Verification

- Static: `validateState` (`validate.zig:89-96`), `authorityIndex` (`election.zig:81-85`), `leader` (`election.zig:157-181`), and `applyJoin`'s count-based revalidation (`membership.zig:113`) all read.

## Follow-up

None. Same class as the fixed empty-list strand; the fix there (revalidation at join) is exactly the hook this needs.

## References

- Code: `src/settings/validate.zig:89-96`, `src/cluster/election.zig:81-85, 157-181`, `src/cluster/membership.zig:105-116`
- Fix: none
