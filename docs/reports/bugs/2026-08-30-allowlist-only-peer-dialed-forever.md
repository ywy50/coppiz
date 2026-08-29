# Bug - an allowlist-only `[[peers]]` entry is dialed forever at the empty address

## TL;DR

- **What failed:** `cmdServe` made every `[[peers]]` entry a seed peer,
  including one that carries only a `public_key`. Such an entry's address is
  the empty string, so the node dialed `""`.
- **Impact:** the documented way to authorize a newcomer the admitter has no
  address for (RFC 0016, PRD 0003 *Admission*) puts the serving node into a
  permanent redial loop: `""` fails to parse as an address, is recorded as a
  failed seed, and is retried for the life of the process. The admission
  itself still works, so the only symptom is a node that never stops
  dialing nothing.
- **Resolution:** fixed. Only an entry that names an address becomes a seed;
  an entry with neither an address nor a key is refused at startup instead
  of being silently ignored.

## Status

Resolved - 2026-08-30. Found by reading.

## Symptom and impact

`config.local` appends `.{ .address = "", .public_key = null }` the moment
it sees a `[[peers]]` header, and nothing later requires an `address` key.
So this is a complete, intended entry:

```toml
[[peers]]
public_key = "a1b2…"        # 64 hex characters, no address
```

RFC 0016 describes exactly this: "the operator edits `[[peers]]` in the
founder's local config with the newcomer's public key". The admitter has no
address for a newcomer that has not joined yet - the newcomer dials in.

`cmdServe` nevertheless pushed `peer.address` into `seed_peers`
unconditionally, so the cluster loop treated `""` as a member to dial.

## Reproduction

`an allowlist-only [[peers]] entry authorizes without becoming a dial
target` in `src/main.zig`: three entries - address only, key only, both.

- Expected: two keys in the allowlist, two addresses to dial, none empty.
- Actual, before the fix: three seed addresses, one of them `""`. Confirmed
  by restoring the unconditional append and running `zig build test`
  (exit 1).

## Root cause

```zig
for (cfg.peers.items) |peer| {
    if (peer.public_key) |hex| { … try allowlist.append(gpa, key); }
    try seed_peers.append(gpa, peer.address);   // <- unconditional
}
```

`[[peers]]` serves two lists that are not the same list: the admission
allowlist (keys) and the startup dial set (addresses). An entry can
legitimately populate either one alone. The loop conflated them.

## Resolution

The loop is now `splitPeers`, a function with the two lists as out
parameters, so the split is stated once and is unit-testable without
spawning a serve:

- an entry with a `public_key` always joins the allowlist (an unparseable
  key is still a startup error rather than a silent drop -
  bug 2026-08-28-cmdserve-silent-allowlist-drop);
- an entry joins the dial set only when it names a non-empty address;
- an entry with neither is refused with `PeerEntryEmpty`. It authorizes
  nobody and dials nothing, so accepting it would mean an operator's typo -
  a `[[peers]]` header whose keys landed under the wrong table - starts a
  node that quietly does not do what was asked.

The diagnostic now names the entry by its position (`[[peers]] entry 2`)
rather than by its address, which for an allowlist-only entry was the empty
string.

## Verification

- Both new tests pass with the fix and fail with the unconditional append
  and the empty-entry check bypassed (`zig build test` exit 1).
- Full gate `zig build test` exit 0 on the branch.
- Not verified here: that the loop's redial of `""` stops, since the fix
  removes the address before the loop ever sees it. The redial mechanism
  itself is unchanged.

## Follow-up

None. Whether the allowlist should learn keys some other way is
[RFC 0016](../../rfcs/0016-allowlist-key-learning.md)'s question and is
untouched.

## References

- Investigation: none
- Code: `src/main.zig` (`splitPeers`, `cmdServe`), `src/config/local.zig`
  (`parseSection`, `Peer`)
- Spec: [RFC 0016](../../rfcs/0016-allowlist-key-learning.md),
  [PRD 0003](../../prds/0003-membership-and-leadership.md) *Admission*
- Related: [2026-08-28 - `cmdServe` silently drops a malformed `[[peers]] public_key` from the allowlist](2026-08-28-cmdserve-silent-allowlist-drop.md)
