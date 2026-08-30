# Bug - the wire encoders cast a journal name's length to u16 unchecked: a 64 KiB name panics the CLI

## TL;DR

- **What failed:** `message.writeU16` (message.zig) casts `usize` to `u16`
  with no bound, and the CLI feeds it journal names straight from argv
  (`cmdAppend`, `cmdRead`, `cmdSettingsSet` -> `encodeAppend`/
  `encodeReadReq`/`encodeSettings`). A name past 65535 bytes panics the CLI
  in a safe build and wraps the length field in a release one.
- **Impact:** CLI crash on absurd-but-legal input (the same class as bug
  2026-08-29-create-journal-name-codec-overflow, which was fixed for the
  chain codec and missed for the wire encoders). No remote reachability -
  the server's decoders are bounded.
- **Resolution:** Resolved - the wire client refuses a journal name past
  the u16 cap before encoding.

## Status

Resolved.

## Symptom and impact

`coppiz append --journal <65536-byte name> --payload x` against a serving
node: the client encodes before sending, `writeU16(buf[0..2],
journal.len)` hits `@intCast(65536)` and panics in Debug; in ReleaseFast
the field wraps to 0 and the server refuses the frame with a confusing
decode error. `framing.max_body_bytes` (17 MiB) does not help - the encode
happens first, and a 64 KiB name is well under the frame cap.

## Reproduction

```sh
coppiz append --journal "$(python3 -c 'print("j"*65536)')" --payload x
```

Debug build: panic "integer cast truncated bits".

## Root cause

`writeU16` (message.zig:77) casts without a bound. The store's own name cap
(`max_journal_name` = 256) is enforced at the chain, not at the wire
client, so nothing on the CLI-to-encoder path checks the length.

## Resolution

Fixed: `Client.append`, `Client.read` and `Client.settings` (net/client.zig)
now call `checkJournalName`, which refuses a name past `maxInt(u16)` with
`error.JournalNameTooLong` before the encoder runs. No real name can reach
the cap - the store refuses names over 256 bytes - so the guard only
converts a panic into a clean error.

## Verification

- Regression test: "a journal name past the wire's u16 length cap is
  refused before encoding" (client.zig).
- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: src/net/message.zig (`writeU16`), src/net/client.zig
  (`append`/`read`/`settings`)
- Fix: this report's resolving commit
