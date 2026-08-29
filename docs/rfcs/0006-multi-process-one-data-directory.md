# RFC 0006 - several processes on one data directory: native multi-process opens or the wire fallback?

## Status

Discussion - opened 2026-08-29. Addresses [OQ 47](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

SQLite lets N processes open one file: file locks plus a busy timeout, so a
host's short-lived processes can read and write the same database beside a
long-lived one. clanker relies on that habit today - its `run`/`repl`
processes write per-session databases directly while `serve` runs (PRD 0005,
*Example host*). coppiz v1 takes the opposite shape: `open` flocks the data
directory to one process, and a second process gets `locked`; short-lived
processes fall back to speaking the replication wire to the long-lived node
(the CLI's wire client, [OQ 47](../open-questions.md)).

**Decision to make.** Is the SQLite habit - several processes opening one
data directory natively - important enough to hosts to become a v1 property
of coppiz, and if so, how is it provided?

**Why now.** The library's shape is not yet frozen (PRD 0005 steps 1-3
shipped; the read/write API is pre-1.0). Adding native multi-process opens
later means a second transport and an admission story bolted onto a frozen
surface; deciding now keeps the door cheap either way. The first host's
constraint is concrete: clanker's `run`/`repl` write session files directly
today, and under v1 they would append through `serve` instead - or this
question is answered.

**Drivers.** Any acceptable option must:

- keep "no external infrastructure at any size" (ADR 0003): the answer is
  inside the library, never a second daemon or a broker;
- keep one owner per data directory: two processes cannot both hold the
  listener/leader role on one directory, or the chain forks before the
  failure detector notices;
- not weaken the single-process case (ADR 0003's "a mechanism that cannot
  be absent at size 1 needs a reason in its PRD");
- reuse what exists where possible: the wire protocol, the framing, the
  member key, and the transport seam are already built.

**Out of scope.** Read-your-own-writes semantics across processes (a
short-lived process that writes then reads must see its write - the wire
fallback already provides this through the owner). Anything past two
processes on one directory that the owner does not mediate.

## Current state

`journal.Node.open` takes an exclusive flock on the data directory
(`<data_dir>/lock`); a second `open` fails `locked` (PRD 0005 *Failure
modes*). The CLI compensates: every command that needs the directory
(`append`, `read`, `head`, `status`, `members`, `doctor`, `settings set`,
`admit`) falls back to the wire client when the lock is held - the client
dials the serving node with the directory's own member key and is admitted
as the operator channel without a join (the glossary's *wire client*).

So a
short-lived process today writes by connecting to the owner over the
replication wire, which is loopback TCP in the standalone deployment. The
embedded-host API (`cluster.ClusterNode.localAppend`/`localReadRange`) is
the in-process shape for a host that *is* the node; a separate process on
the same directory is not supported natively.

## Options considered

### Option A - keep the flock + wire fallback (status quo)

- **What it is:** one process owns the directory; every other process
  reaches it over the existing replication wire (loopback TCP today).
  Short-lived writes become loopback appends through the owner; the owner
  is the leader/forwarder exactly as for any wire client.
- **Maturity:** shipped. The wire fallback exists, is exercised by the
  CLI's tests, and the operator channel (dial with the directory's key,
  admitted without a join) is a deliberate design.
- **How it would fit:** nothing changes. clanker's `run`/`repl` would
  append through `serve` (PRD 0005 already says this is the v1 answer).
- **Pros:** one transport to own; no new admission surface; the owner
  already serializes every mutation, so correctness is the same as any
  wire client; the embedded host keeps the SQLite-like in-process shape.
- **Cons:** a short-lived write pays a loopback round-trip and needs the
  owner running - the process that holds the lock is load-bearing even for
  a host that only writes occasionally. A host that wants "open the
  directory and write" without a long-lived owner gets `locked`.
- **Cost to adopt:** none - it is the shipped state.
- **Cost to leave:** the fallback stays regardless; only the "no native
  multi-process" stance would change, which costs nothing to reverse
  before a second host needs it.
- **Evidence:** the shipped CLI wire fallback and the glossary's *wire
  client*; PRD 0005's multi-process paragraph.

### Option B - native multi-process opens via a unix-socket transport in the existing seam

- **What it is:** the library opens a unix socket inside the data
  directory beside the flock. A process that cannot take the lock does not
  fail: it connects to the socket and speaks the *existing* replication
  protocol to the owner - the same message set, the same framing, the same
  operator-channel admission (dial with the directory's key). The
  transport seam from OQ 19's decision (`Conn`/`Listener`/`Transport` in
  `src/net/transport.zig`, TCP plus the in-memory hub) gains one more
  implementation; the loop code is unchanged.
- **Maturity:** the pieces exist (the seam, the message set, the operator
  channel); a unix-socket transport is a small addition, not a new
  protocol.
- **How it would fit:** `Node.open` tries the flock; on `locked`, it
  checks for the socket and connects instead of failing. The owner keeps
  the listener and the leader role; short-lived processes append through
  the socket exactly as through the wire - the same code path a follower
  uses to forward.
- **Pros:** the SQLite habit returns: open the directory, write, close -
  no long-lived owner required for the write itself beyond the one holding
  the lock; still zero external infrastructure (a unix socket is a file in
  the data dir); reuses the whole protocol and admission; the owner's
  serialization is untouched.
- **Cons:** a second transport to own (socket lifecycle, permissions, the
  owner's accept loop); admission now has to distinguish the operator
  channel from a wire client (it already does); the owner is still
  required - the habit is "write beside a long-lived process", not "any
  process can be the owner".
- **Cost to adopt:** the transport implementation plus `open`'s fallback
  path plus tests; the protocol and admission are reused.
- **Cost to leave:** nothing - the seam makes it an additive change.
- **Evidence:** the transport seam and message set as shipped (OQ 19
  resolved); PRD 0005's multi-process paragraph.

### Option C - SQLite-style file-level sharing (the out-of-the-box option)

- **What it is:** mimic SQLite's own mechanism: file locking and a busy
  timeout over the same files, so any process can open and the OS
  serializes. coppiz would have to make its on-disk format safe for
  concurrent writers - which it is not designed to be (the fold is a
  pure function of the chain, but the store and queue assume one writer).
- **Pros:** the exact SQLite habit; no owner process.
- **Cons:** coppiz's formats assume a single writer; concurrent writers
  would need a new concurrency layer over the segments, queue and fold -
  a large, risky change to the storage core for a habit one host has; the
  chain already needs a leader, so "any process writes" still funnels to
  one sequencer - the file-level sharing buys little over the socket.
- **Cost to adopt:** a storage-core concurrency redesign. Not justified by
  the driver set.
- **Cost to leave:** none.
- **Evidence:** design reasoning; SQLite's own documentation of its
  locking model as the pattern being copied.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** nothing changes; clanker's `run`/`repl` append through `serve`.
- **If B:** the socket transport lands with the seam; short-lived hosts
  get the habit without a daemon.
- **If C:** a storage-core redesign now, before the format is proven.

### Medium term (3-12 months)

- **If A:** the first non-clanker host decides whether the fallback is
  enough; if it wants the habit, B is still cheap because of the seam.
- **If B:** the operator channel and the wire client share one code path;
  the socket is the obvious place for a future local control surface.

### Long term (12+ months)

- **If A:** native multi-process opens are a format-frozen retrofit if a
  host ever needs them.
- **If B:** the socket becomes the local IPC for anything that does not
  want the wire - the natural answer to OQ 46's "several processes on one
  machine" host shapes.

## Recommendation

**Recommended option:** A for v1 - keep the flock + wire fallback - and
record that B (the unix-socket transport in the existing seam) is the
planned answer if a second host needs the SQLite habit; do not build it
until that host exists.

**Confidence:** 7/10

**Why this confidence.** The shipped fallback already answers the one
concrete host's need (clanker's `run`/`repl` append through `serve`), and
B stays cheap because the transport seam makes it additive. What would move
it up: a second host (OQ 46) stating that its short-lived processes cannot
or will not talk to a long-lived owner. What would sink it: evidence that
clanker's `run`/`repl` cannot practically route through `serve` (a real
integration test on the clanker branch would show this).

**Rationale.** A is the only option with no new surface and it satisfies
every driver; C fails driver 3 (it rewrites the storage core) and driver 1
(the file-level answer still needs one sequencer). B is attractive but its
entire value is the SQLite habit for hosts that do not exist yet - the
seam keeps it cheap, so waiting costs nothing and building now spends a
transport on a "perhaps" (the same reasoning OQ 12 applied to `freshest`).

**Reversibility.** Fully reversible in both directions: A to B is an
additive transport in the seam; B to A is removing it.

## Open questions

- Does clanker's `run`/`repl` integration actually need direct writes, or
  is appending through `serve` acceptable? (the clanker branch's spike,
  PRD 0005 phase 5)
- Which of OQ 46's host shapes, if any, needs short-lived processes that
  cannot route through a long-lived owner? (OQ 46)

## Next steps / action items

- [ ] Decide the v1 stance: keep A (recommended) or commission B.
- [ ] If B: a transport test in the seam first (the hub already proves the
      shape), then the socket implementation and `open`'s fallback.
- [ ] Write the ADR once decided; update OQ 47's status.

## References

- [OQ 47](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0005](../prds/0005-embedding-the-library-as-the-product.md) - the
  multi-process paragraph and the wire fallback.
- [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md) -
  the "no external infrastructure" driver.
- OQ 19's resolution (own binary framing over one TCP connection, the
  transport seam) - recorded in PRD 0003's status and implemented in
  `src/net/`.
