# Bug - Wire read of an unknown journal silently succeeds with empty output; the local read errors

## TL;DR

- **What failed:** `onReadReq` answers an unknown journal name with an empty `read_page` and exit 0; `coppiz read` against an unlocked dir returns `error.UnknownJournal`. Same command, different behavior depending on whether the node is serving.
- **Impact:** A typo'd journal name in `coppiz read` over the wire produces silent empty output instead of an error.
- **Resolution:** Still open. Statically validated.

## Status

Resolved.

## Symptom and impact

`onReadReq` (`node.zig:2413-2420`): unknown name → empty page with `next = (0,0)`. The wire `append` path returns a named `unknown_journal` refusal, and the local read (`main.zig:392-393`) returns `error.UnknownJournal` - the read path is the odd one out.

## Reproduction

Not dynamically reproduced; statically certain. `coppiz read --journal bogus` against a serving node prints nothing, exit 0; against an unlocked dir it errors.

## Root cause

The unknown-journal case was given an empty success response instead of the named error the other commands use.

## Resolution

Fixed: a read of an unknown journal refuses with a named refusal — `read_page` gained a `refusal` field and the client maps it to `error.UnknownJournal`, matching the local read.

## Verification

- Static: `onReadReq` (`node.zig:2413-2420`), local `cmdRead` (`main.zig:392-393`), and `onAppend`'s refusal (`node.zig:1382-1384`) read.

## Follow-up

None. Low severity.

## References

- Code: `src/cluster/node.zig:2413-2420` (`onReadReq`), `src/main.zig:392-393` (`cmdRead`)
- Fix: none
