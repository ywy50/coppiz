# Bug - A non-empty authority list that matches no member strands the cluster leaderless (the empty-list fix covered only `len == 0`)

## TL;DR

- **What failed:** `validateState` refuses only an *empty* authority list. A non-empty list whose entries match no member - a 64-hex public key pasted instead of a 32-hex id, a dead hostname, any non-matching string - passes genesis and every join; once the cluster grows past n=1, `leader()` finds no authority and `fallback = stall` returns `null`.
- **Impact:** The cluster strands permanently - and, since only the leader can author settings entries, the bad list can never be corrected online. The same no-self-heal class the empty-list fix (2026-08-28-join-can-strand-cluster-leaderless) closed.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

`validateState` (`validate.zig:89-96`): `empty_ok` guards `list.len == 0` only. `authorityIndex` (`election.zig:81-85`) matches a verbatim address or a 32-hex id - anything else is silently skipped when `leader()` scans for an authority. At genesis n=1 the lone member leads itself (`election.zig:161`), so the bad list is invisible; `applyJoin` re-validates only the *count* (`membership.zig:113`) - a non-empty garbage list passes. At n≥2: `leader()` (`election.zig:176-179`) finds no live authority → `null` → `append` answers `no_leader` forever; no diagnostic anywhere.

## Reproduction

Not dynamically reproduced; statically certain. Genesis with `leadership.authorities = ["ghost.example"]` (or a 64-char hex key), then a second member joins.

## Root cause

The validation checks list *emptiness*, not list *resolvability*: an authority entry that matches no member is indistinguishable from a typo'd entry at validation time, and nothing refuses it.

## Resolution

Not yet fixed. Suggested direction: validate each authority entry against the member table at settings-apply time (an entry that matches no current member is either refused or warned), and/or make `fallback = stall` recoverable by authoring settings from a live member. A regression test should grow past n=1 with a ghost authority and expect a refusal, not a silent strand.

## Verification

- Static: `validateState` (`validate.zig:89-96`), `authorityIndex` (`election.zig:81-85`), `leader` (`election.zig:157-181`), and `applyJoin`'s count-based revalidation (`membership.zig:113`) all read.

## Follow-up

None. Same class as the fixed empty-list strand; the fix there (revalidation at join) is exactly the hook this needs.

## References

- Code: `src/settings/validate.zig:89-96`, `src/cluster/election.zig:81-85, 157-181`, `src/cluster/membership.zig:105-116`
- Fix: none
