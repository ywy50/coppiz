# Bug - a member can occupy another member's id-named authority slot by advertising its id as an address

## TL;DR

- **What failed:** `authorityIndex` matched each `leadership.authorities`
  entry against *both* the member's advertised address and the hex of its
  id. A member's address is self-declared, and hex is a legal address.
- **Impact:** under `configured` or `combined`, any admitted member could
  present itself as the authority named by `<hex of some other member's
  id>`, lead a term that should have gone to that authority, and lead an
  election that `fallback = stall` should have refused. The id form is the
  one PRD 0003 calls unspoofable.
- **Resolution:** fixed. Each entry is now read as *either* an id or an
  address, never both.

## Status

Resolved. Found by reading `src/cluster/election.zig`; no investigation
record.

## Symptom and impact

PRD 0003 *Design* lets an authority be written either way:

> `authorities[]` entries are member ids, or addresses/DNS names that a
> member's `join` entry advertised

and PRD 0003 *Identity* is explicit about why the id form is trustworthy:

> A member is an Ed25519 keypair plus a 128-bit member id derived from the
> public key (so the id cannot be chosen to collide).

The two forms shared one namespace and were tested with an `or`:

```zig
for (authorities, 0..) |authority, i| {
    if (std.mem.eql(u8, authority, member.address)) return i;
    if (isHexId(authority, &member.id)) return i;
}
```

The address half of that test is entirely under the peer's control. `onHello`
copies the dialer's `h.address` verbatim into the member map, and
`admitNewcomer` copies it verbatim into the `join` payload; the only filter is
`addressSafe`, which requires printable ASCII of at most 300 bytes. Every
character of a 32-digit hex id is printable ASCII, so a member may advertise
`address = <hex of any other member's id>` and be admitted normally.

That member is then reported at the impersonated authority's list index:

- under `configured`, both share the index, `compareRank` falls through to
  seniority, and the impostor wins if it joined earlier;
- under `combined`, it passes the authority filter and can win the
  `freshest` tiebreak;
- in either mode, when the real authority is down, `leader(...)` returns the
  impostor instead of `null`, so a cluster configured for
  `fallback = stall` - the CP posture, the whole reason to name authorities
  by id - keeps writing under a leader the operator never named.

The derivation of the id from the public key is untouched; what is defeated
is the *lookup*, which never consulted the id when an address matched first.

## Reproduction

`an authority named by id is not matched by a member's advertised address`
in `src/cluster/election.zig`. Two members, `authorities = [<hex of B's
id>]`, A senior to B and advertising B's id hex as its address, B down.

Before the fix, `authorityIndex` returns index 0 for A and `leader` returns
A. The test fails at the first assertion:

```
error: 'cluster.election.test.an authority named by id is not matched by a
member's advertised address' failed:
    src/cluster/election.zig:467:5
        try std.testing.expect(authorityIndex(inputs.authorities, m.view(0)) == null);
```

After the fix A matches nothing, and `stall` refuses writes. The test also
pins the two directions that must not change: B still matches its own
id entry and still leads when live, and an entry that is not hex of the id's
width is still matched against the advertised address.

## Root cause

One list holds two naming forms, and the entry itself says which form it is:
an id entry is exactly `hex_len` hex digits. Nothing classified the entry -
both comparisons ran against every entry, so an address that happened to
look like an id matched the id slot.

## Resolution

`authorityNamesAnId(authority)` classifies each entry once - exactly
`hex_len` characters, all hex digits - and `authorityIndex` compares it
against the id when it does and against the address when it does not. The
classification is per entry, so a list may still mix the two forms, which is
what the PRD describes.

The consequence for an operator is narrow and worth stating: an address that
is exactly 32 hex characters can no longer be used as an address entry. That
address form is indistinguishable from an id by construction, so it was
already ambiguous.

## Verification

- The new test fails at the `authorityIndex` assertion before the change and
  passes after.
- The existing `configured` and `combined` table tests, including the
  hex-id and ghost-authority cases, pass unchanged.
- `zig build test` green on the branch.

## Follow-up

PRD 0003 says an address entry is "resolved to the member id at fold time";
today it is resolved at election time against the live view's address. That
is a separate design gap and is not addressed here.

## References

- Code: `src/cluster/election.zig` (`authorityIndex`, `authorityNamesAnId`),
  `src/cluster/node.zig` (`addressSafe`, `onHello`, `admitNewcomer`)
- PRD: [PRD 0003](../../prds/0003-membership-and-leadership.md) *Identity*
  and *Election: a pure function, not a protocol*
- Related: [2026-08-28 - sweep3: a non-empty authority list matching no
  member strands the cluster](2026-08-28-sweep3-ghost-authority-strand.md)
  (an entry matching *nobody*; this one is an entry matching the *wrong*
  member)
- Fix: this PR
