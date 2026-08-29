# Bug - Settings/join/create-journal decode errors fold `OutOfMemory` into a normal refusal, diverging the member's fold

## TL;DR

- **What failed:** The decode catch-sites (`mapSettingsDecodeError` and the `genesis`/`create_journal`/`join` catches) fold `OutOfMemory` into a refusal (`InvalidSettings`/`BadGenesis`/`BadControlPayload`). The apply side and `registerEntry`'s contract treat OOM as fatal - a refusal leaves that member's fold behind the group.
- **Impact:** On an allocator failure while decoding one entry, the member refuses it while everyone else folds it - permanent fold divergence, silently served onward.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

- `mapSettingsDecodeError` (`chain.zig:915-921`): the `else` arm folds `OutOfMemory` into `InvalidSettings`.
- `applyGenesis`'s catch → `BadGenesis` (`chain.zig:555`), `decodeCreateJournalPayload` catch → `BadControlPayload` (`:608`), `applyJoin` catch → `BadControlPayload` (`membership.zig:93-94`).

The apply side does the opposite: `mapSettingsApplyError` (`chain.zig:923-928`) propagates `OutOfMemory`, `applyCheckpoint`'s `expiryCandidates`/`removalSet` use bare `try`, and `registerEntry`'s comment states the rule ("an OutOfMemory here leaves the fold partially advanced, which the caller treats as fatal"). `onSlot`'s error switch then swallows the refusal as "the chain's rules decide" - the OOM'd member keeps serving a fold that diverges from every member that did not OOM.

## Reproduction

Not dynamically reproduced (needs an injected allocator failure at the decode); statically certain from the mapping.

## Root cause

The decode-side error mapping contradicts the apply-side convention: OOM must propagate as `ApplyError.OutOfMemory` so callers treat it as fatal.

## Resolution

Not yet fixed. Suggested fix: propagate `OutOfMemory` through the decode catch-sites (special-case it before the generic mapping). A regression test should fail the payload decode under a failing allocator and assert the fold treats it as fatal, not as a refusal.

## Verification

- Static: both error maps and all four catch-sites read; the apply-side OOM handling read as the intended convention.

## Follow-up

None. Narrow trigger (allocator failure), but the divergence is silent and permanent.

## References

- Code: `src/journal/chain.zig:555, 608, 915-928`, `src/cluster/membership.zig:93-94`, `src/cluster/node.zig:1821-1824` (`onSlot` swallow)
- Fix: none
