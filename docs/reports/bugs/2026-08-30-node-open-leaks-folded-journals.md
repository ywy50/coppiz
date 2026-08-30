# Bug - a `Node.open` failure after the fold leaks every folded journal

## TL;DR

- **What failed:** `Node.open`'s errdefer frees only the journals *map*;
  the `JournalState` values (each holding a `FoldState`: settings, authors
  and entries maps, owned strings) that `foldAll` allocated are never
  deinit'ed on this path - `Node.deinit` does that, and it is not the
  errdefer.
- **Impact:** an open failure after `foldAll` - a store read error in
  `replayQueue`, a failed group-id lookup - leaks every data journal's fold
  state. An embedded host that retries opens (PRD 0005) grows memory with
  each attempt.
- **Resolution:** Resolved - the errdefer now deinits and destroys each
  `JournalState`, mirroring `Node.deinit`.

## Status

Resolved.

## Symptom and impact

`Node.open` (journal.zig) registers:

```zig
errdefer {
    node.control.deinit();
    node.journals.deinit();   // frees only the map table
    node.followers.deinit(allocator);
}
```

`foldAll` allocates one `JournalState` per data journal (`journal.zig`,
`foldAll`), and `node.journals.deinit()` frees only the hash-map table, not
the values. Any error after `foldAll` - `store.groupIdOf` failing, a
corrupt record during `replayQueue`'s store reads - returns with every
folded journal's settings, authors/entries maps and owned strings still
allocated.

## Reproduction

Not dynamically reproduced; statically certain. Fail an open after
`foldAll` under the GPA and watch the leak check flag the journals.

## Root cause

The errdefer mirrors `Node.deinit`'s *shape* but not its value cleanup:
`deinit` iterates the map and destroys each `JournalState`; the errdefer
only freed the map.

## Resolution

Fixed: the errdefer iterates `node.journals` and deinits + destroys each
`JournalState` before freeing the map, exactly as `Node.deinit` does.

## Verification

- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: src/journal/journal.zig (`Node.open`, `Node.deinit`, `foldAll`)
- Fix: this report's resolving commit
