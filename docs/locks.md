# Exclusive resource leases

Use `.local/scripts/lease-lock.py` when agents must not drive the same local
resource concurrently: a live client, deployment environment, hardware device,
migration, benchmark machine, or other stateful process. It is separate from a
TODO claim: a TODO owns work; a lease owns a shared resource.

The lease file is private and human-readable. A held lease contains `running`,
`session`, `acquired`, and `heartbeat`; a released lease contains `running=no`.
Updates are serialized, ownership is checked on every heartbeat/release, and
the default heartbeat is 30 seconds with a 120-second stale threshold.

Generate a session ID, then run a command while holding the default lease:

```sh
session=$(.local/scripts/new-session-id.sh codex)
.local/scripts/lease-lock.py run --session "$session" -- your-command
```

For a resource that might stay live after a crash, supply a probe which exits
zero only while that resource is live. This lets the tool reject both a free
lock with a still-live resource and a stale foreign lease whose resource has
not actually stopped:

```sh
.local/scripts/lease-lock.py acquire --session "$session" --probe 'pgrep -f your-resource'
```

Without `--probe`, a stale foreign lease is deliberately not reclaimed. Choose
and document a probe appropriate to the project; the kit cannot safely guess
how a particular client, deployment, or device looks when alive.

Inspect or manually renew/release an owned lease:

```sh
.local/scripts/lease-lock.py status
.local/scripts/lease-lock.py heartbeat --session "$session"
.local/scripts/lease-lock.py release --session "$session"
```
